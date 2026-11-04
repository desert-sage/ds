# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`Engine.facts` — working memory as a Mapping[FactId, Fact] view.

Two read-outs of working memory exist: the stream (`fact_assert` events,
each read through `engine.facts[fid]` while the fact is live) and the walk
(`iter(engine.facts)` and `engine.facts.of(schema)`, through
`ds_engine_for_each_fact`, which never consults the stream). A reader can hold
the two against each other, so the last test here pins that they agree on a
two-schema engine, by id and by value.
"""

import dataclasses
from collections.abc import Mapping

import pytest

import pyds
from pyds import Fact, FactId

_TWO_SCHEMAS = """
schema Reading scope logical:
    zone: String key
    level: Int key

schema High scope logical:
    zone: String key

rule flag_high:
    Reading r where r.level > 5
->
    emit High logical zone: r.zone
"""

_TTL = """
schema Ping scope ttl 5s:
    n: Int
"""


def _rows(facts):
    """Return (schema, sorted slot items) per fact, sorted."""
    return sorted((f.schema, tuple(sorted(f.slots.items()))) for f in facts)


def _engine():
    eng = pyds.from_source(_TWO_SCHEMAS)
    eng.assert_("Reading", zone="cellar", level=3)
    eng.assert_("Reading", zone="attic", level=9)
    eng.pump()
    return eng


def test_facts_is_a_mapping_of_fact_ids_to_facts():
    eng = _engine()
    assert isinstance(eng.facts, Mapping)
    assert len(eng.facts) == 3
    assert all(type(fid) is FactId for fid in eng.facts)
    assert all(type(f) is Fact for f in eng.facts.values())
    assert [f.id for f in eng.facts.values()] == list(eng.facts)


def test_facts_iterate_in_id_order():
    eng = _engine()
    ids = list(eng.facts)
    assert ids == sorted(ids) and len(set(ids)) == 3


def test_of_returns_one_schemas_facts_in_id_order():
    eng = _engine()
    readings = eng.facts.of("Reading")
    assert _rows(readings) == [
        ("Reading", (("level", 3), ("zone", "cellar"))),
        ("Reading", (("level", 9), ("zone", "attic"))),
    ]
    assert [f.id for f in readings] == sorted(f.id for f in readings)
    assert _rows(eng.facts.of("High")) == [("High", (("zone", "attic"),))]


def test_of_an_unknown_schema_is_an_error_not_an_empty_list():
    eng = _engine()
    with pytest.raises(ValueError, match="'Nope'"):
        eng.facts.of("Nope")


def test_of_takes_a_schema_name():
    eng = _engine()
    with pytest.raises(TypeError, match="str, not int"):
        eng.facts.of(1)


def test_indexing_reads_one_live_fact():
    eng = pyds.from_source(_TWO_SCHEMAS)
    fid = eng.assert_("Reading", zone="attic", level=9)
    fact = eng.facts[fid]
    assert fact.id == fid and fact.schema == "Reading"
    assert dict(fact.slots) == {"zone": "attic", "level": 9}
    assert eng.facts[int(fid)] == fact


def test_a_fact_that_is_not_live_is_a_key_error():
    eng = pyds.from_source(_TWO_SCHEMAS)
    fid = eng.assert_("Reading", zone="attic", level=1)
    eng.retract(fid)
    with pytest.raises(KeyError, match=r"no live fact FactId\("):
        eng.facts[fid]
    assert eng.facts.get(fid) is None
    assert fid not in eng.facts


@pytest.mark.parametrize("key", [True, "1", 1.0, None])
def test_a_key_no_fact_can_have_is_absent(key):
    """As a dict keyed by FactId answers: KeyError, and not `in`."""
    eng = _engine()
    assert key not in eng.facts
    with pytest.raises(KeyError):
        eng.facts[key]


def test_in_asks_whether_a_fact_is_live():
    eng = pyds.from_source(_TWO_SCHEMAS)
    fid = eng.assert_("Reading", zone="attic", level=1)
    assert fid in eng.facts
    eng.retract(fid)
    assert fid not in eng.facts


def test_a_fact_carries_when_it_was_asserted():
    eng = pyds.from_source(_TWO_SCHEMAS)
    eng.clock.mode = pyds.ClockMode.MOCK
    eng.clock.set(7_000)
    fid = eng.assert_("Reading", zone="attic", level=1)
    assert eng.facts[fid].asserted_ns == 7_000


def test_a_logical_fact_has_no_deadline():
    eng = pyds.from_source(_TWO_SCHEMAS)
    fid = eng.assert_("Reading", zone="attic", level=1)
    assert eng.facts[fid].ttl_deadline_ns is None


def test_a_ttl_fact_carries_its_deadline():
    eng = pyds.from_source(_TTL)
    eng.clock.mode = pyds.ClockMode.MOCK
    eng.clock.set(1_000)
    fid = eng.assert_("Ping", n=1)
    assert eng.facts[fid].ttl_deadline_ns == 1_000 + 5_000_000_000


def test_a_fact_is_a_frozen_snapshot():
    eng = pyds.from_source(_TWO_SCHEMAS)
    fid = eng.assert_("Reading", zone="attic", level=1)
    fact = eng.facts[fid]
    with pytest.raises(dataclasses.FrozenInstanceError):
        fact.schema = "High"
    with pytest.raises(TypeError):
        fact.slots["level"] = 2
    eng.retract(fid)
    assert fact.schema == "Reading" and fact.slots["level"] == 1


def test_equal_facts_hash_alike():
    eng = pyds.from_source(_TWO_SCHEMAS)
    fid = eng.assert_("Reading", zone="attic", level=1)
    a, b = eng.facts[fid], eng.facts[fid]
    assert a == b and hash(a) == hash(b)
    assert {a, b} == {a}


def test_facts_on_an_empty_engine_is_empty():
    eng = pyds.from_source(_TWO_SCHEMAS)
    assert len(eng.facts) == 0 and list(eng.facts) == []
    assert eng.facts.of("High") == []


def test_facts_follow_retraction():
    eng = pyds.from_source(_TWO_SCHEMAS)
    h = eng.assert_("Reading", zone="attic", level=9)
    eng.pump()
    assert _rows(eng.facts.of("High")) == [("High", (("zone", "attic"),))]
    eng.retract(h)
    eng.pump()
    assert list(eng.facts) == []


def test_the_view_reads_the_engine_each_time():
    eng = pyds.from_source(_TWO_SCHEMAS)
    view = eng.facts
    fid = eng.assert_("Reading", zone="attic", level=1)
    assert len(view) == 1 and fid in view


def test_the_two_read_outs_agree():
    """The stream's view and the walk's name the same facts, by id and by value.

    The stream's view is the fact_assert events, read while live; the walk's
    is facts.of.
    """
    eng = pyds.from_source(_TWO_SCHEMAS)
    shadow = {}

    def on_event(ev):
        match ev:
            case pyds.events.FactAssert(fact_id=fid):
                shadow[fid] = eng.facts[fid]
            case pyds.events.FactRetract(fact_id=fid):
                shadow.pop(fid, None)

    def walked():
        return {f.id: f for s in ("Reading", "High") for f in eng.facts.of(s)}

    eng.on_event = on_event
    h = eng.assert_("Reading", zone="cellar", level=3)
    eng.assert_("Reading", zone="attic", level=9)
    eng.pump()
    assert walked() == shadow
    assert set(eng.facts) == set(shadow)
    assert len(shadow) == 3

    eng.retract(h)
    eng.pump()
    assert walked() == shadow
    assert set(eng.facts) == set(shadow)
    assert len(shadow) == 2
