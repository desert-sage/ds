# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LFAC.2.5.1 tolerance-aware dedup.

A schema slot declared with `tolerance N.NN` causes the engine
to dedup re-asserts whose values are within tolerance of an
existing fact — the same fact, fact_count unchanged. Without
tolerance, a reassert with a different value is a replace.

The reassert is still RECORDED ([RFCS.6.7]): the event
marks an assert arriving, not a fact being created, and it
carries the stored value rather than the absorbed one.

Wire-format: the tolerance rides on the Slot atom's `tolerance`
field.
"""

import pyds

_TOLERANCE = """
schema Sensor scope logical:
    entity_id: String key
    state: Float mutable tolerance 0.5
"""


def test_within_tolerance_reassert_does_not_create_new_fact():
    """state=10.0 then state=10.3, within 0.5 tolerance, does NOT increase fact_count."""
    eng = pyds.from_source(_TOLERANCE)

    eng.assert_("Sensor", entity_id="dev1", state=10.0)
    eng.assert_("Sensor", entity_id="dev1", state=10.3)
    eng.pump()

    assert len(eng.facts) == 1, f"tolerance dedup didn't suppress: count={len(eng.facts)}"


def test_outside_tolerance_reassert_replaces_fact():
    """state=10.0 then state=11.0, a gap of 1.0 over the 0.5 tolerance, replaces the fact.

    It is a MEANINGFUL change on the same identity key (entity_id="dev1"), so
    it REPLACES the live fact: LFAC.1.7 keeps exactly one live fact per
    identity key, and the update is a retract+assert replace (LFAC.2.5.3).
    count stays 1: identity is the declared key, not the value.
    """
    eng = pyds.from_source(_TOLERANCE)

    eng.assert_("Sensor", entity_id="dev1", state=10.0)
    eng.assert_("Sensor", entity_id="dev1", state=11.0)
    eng.pump()

    assert len(eng.facts) == 1, (
        f"outside-tolerance reassert must REPLACE (one live fact per key): count={len(eng.facts)}"
    )


def test_within_tolerance_reassert_records_the_stored_value():
    """A tolerance-absorbed reassert IS recorded ([RFCS.6.7]).

    It is recorded uniformly, and two things hold:

      (a) the event records an assert ARRIVING, not a fact being created, so
          absorption does not suppress it; and
      (b) the event carries the STORED value, not the arriving one — 10.0,
          never 10.3. The arriving value was absorbed; it is not what the
          fact base holds, so recording it would put a value on the stream
          that no reader could ever observe by querying.

    Both are checked here: the same fact_id (nothing new was created) and
    the stored 10.0 (the payload is the fact, not the message). The fact is
    read from inside the callback, the documented-live window.
    """
    eng = pyds.from_source(_TOLERANCE)
    events = []
    seen = []

    def sink(ev):
        events.append(ev)
        if isinstance(ev, pyds.events.FactAssert):
            slots = eng.facts[ev.fact_id].slots
            seen.append((ev.fact_id, slots["state"]))

    eng.on_event = sink

    eng.assert_("Sensor", entity_id="dev1", state=10.0)
    eng.assert_("Sensor", entity_id="dev1", state=10.3)
    eng.pump()

    asserts = [e for e in events if isinstance(e, pyds.events.FactAssert)]
    assert len(asserts) == 2, (
        f"a tolerance-absorbed reassert is recorded too (RFCS.6.7); got {asserts!r}"
    )
    assert seen[0][0] == seen[1][0], (
        f"absorption must not create a second fact — the recorded assert "
        f"refers to the fact already stored; got handles {seen!r}"
    )
    assert seen[1][1] == 10.0, (
        f"the second assert must carry the STORED 10.0, not the absorbed 10.3; got {seen[1][1]!r}"
    )


def test_meaningful_update_emits_assert_then_retract_pair():
    """A meaningful change to a logical fact streams FACT_ASSERT(new), FACT_RETRACT(old).

    Here the change is an outside-tolerance `state` update on the same
    `entity_id`. It surfaces on the stream as that pair, never a silent
    in-place mutation (LFAC.2.5.3). The arriving assert comes first
    and the retract it causes after it (RFCS.6.7). The initial assert
    fires one fact_assert; the meaningful reassert adds exactly one more
    fact_assert and then one fact_retract — and a MODIFY is never emitted.
    """
    eng = pyds.from_source(_TOLERANCE)
    events = []
    eng.on_event = events.append

    eng.assert_("Sensor", entity_id="dev1", state=10.0)
    eng.pump()
    eng.assert_("Sensor", entity_id="dev1", state=11.0)  # gap 1.0 > 0.5 tol
    eng.pump()

    asserts = [e for e in events if isinstance(e, pyds.events.FactAssert)]
    retracts = [e for e in events if isinstance(e, pyds.events.FactRetract)]
    modifies = [e for e in events if isinstance(e, pyds.events.FactModify)]
    assert len(asserts) == 2, f"expected 2 fact_assert (initial + replace), got {asserts!r}"
    assert len(retracts) == 1, f"meaningful update must emit FACT_RETRACT(old); got {retracts!r}"
    assert modifies == [], f"FACT_MODIFY is reserved-not-emitted; got {modifies!r}"
    fact_kinds = [e.kind for e in events if e.kind in ("fact_assert", "fact_retract")]
    assert fact_kinds == ["fact_assert", "fact_assert", "fact_retract"], (
        f"the replacement's FACT_ASSERT must precede the retract it causes "
        f"(RFCS.6.7); got {fact_kinds!r}"
    )


_NO_TOLERANCE = """
schema Sensor scope logical:
    entity_id: String key
    state: Float mutable
"""


def test_default_no_tolerance_reassert_replaces_fact():
    """Without `tolerance`, state=10.0 then state=10.001 is a replace, not a second fact.

    The two differ under exact equality, so the second assert is a MEANINGFUL
    change on the same identity key (entity_id="dev1"). LFAC.1.7 keeps one
    live fact per key; count stays 1.
    """
    eng = pyds.from_source(_NO_TOLERANCE)

    eng.assert_("Sensor", entity_id="dev1", state=10.0)
    eng.assert_("Sensor", entity_id="dev1", state=10.001)
    eng.pump()

    assert len(eng.facts) == 1, (
        f"no-tolerance reassert with a changed value must REPLACE "
        f"(one live fact per key): count={len(eng.facts)}"
    )
