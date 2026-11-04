# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""``engine.debug``: what an engine says about its own state, as values.

Each reader returns frozen dataclasses, never dicts (PY.4), and their fields
keep libds's names. A fact is named by a live ``FactId`` (PYTHON_BINDING.md
§5.1), and a rule filter names a rule the program has, so a mistake is an
exception rather than an empty answer that reads as a true one.
"""

import dataclasses

import pytest

import pyds

# All three node kinds, a join, a negative beta, and a logical emit.
_SRC = """\
schema Sensor scope logical:
    entity_id: String key
    state: Int mutable

schema Suppress scope logical:
    entity_id: String key

schema Alarm scope logical:
    entity_id: String key

rule raise_alarm:
    Sensor s where s.state > 50
    no Suppress x where x.entity_id == s.entity_id
->
    emit Alarm logical entity_id: s.entity_id

rule note_alarm:
    Alarm a
->
    log info "alarm {a.entity_id}"
"""


@pytest.fixture
def run():
    """Return an engine that has fired both rules once, with its sensor and its alarm."""
    eng = pyds.from_source(_SRC)
    sensor = eng.assert_("Sensor", entity_id="hall", state=60)
    eng.pump()
    (alarm,) = eng.facts.of("Alarm")
    yield eng, sensor, alarm.id
    eng.close()


def test_debug_is_a_namespace_on_the_engine(run):
    eng, _, _ = run
    assert isinstance(eng.debug, pyds.Debug)
    assert repr(eng.debug) == "<pyds.Debug>"


def test_the_old_method_spellings_are_gone(run):
    eng, _, _ = run
    for name in ("get_justifiers", "rete_network", "rete_match_trace", "refracted_activations"):
        assert not hasattr(eng, name), name


# ---- justifiers ------------------------------------------------------------


def test_a_derived_fact_is_justified_by_the_rule_that_emitted_it(run):
    eng, _, alarm = run
    (just,) = eng.debug.justifiers(alarm)
    assert isinstance(just, pyds.Justifier)
    assert just.rule_name == "raise_alarm"
    assert type(just.timetag) is int
    with pytest.raises(dataclasses.FrozenInstanceError):
        just.rule_name = "x"  # type: ignore[misc]  # the assignment under test


def test_a_fact_the_host_asserted_has_no_justifiers(run):
    eng, sensor, _ = run
    assert eng.debug.justifiers(sensor) == []


# ---- a fact id must name a live fact ---------------------------------------


@pytest.mark.parametrize("reader", ["justifiers", "match_trace"])
@pytest.mark.parametrize("fact_id", [pyds.FactId(999), 2**64, -1])
def test_a_fact_id_with_no_live_fact_is_a_key_error(run, reader, fact_id):
    eng, _, _ = run
    with pytest.raises(KeyError):
        getattr(eng.debug, reader)(fact_id)


@pytest.mark.parametrize("reader", ["justifiers", "match_trace"])
@pytest.mark.parametrize("fact_id", [True, "1", 1.0])
def test_a_fact_id_that_is_not_an_integer_is_a_type_error(run, reader, fact_id):
    eng, _, _ = run
    with pytest.raises(TypeError):
        getattr(eng.debug, reader)(fact_id)


def test_a_retracted_fact_is_a_key_error(run):
    eng, sensor, _ = run
    eng.retract(sensor)
    with pytest.raises(KeyError):
        eng.debug.match_trace(sensor)


# ---- the network -----------------------------------------------------------


def test_the_network_is_a_value_of_nodes_and_edges(run):
    eng, _, _ = run
    net = eng.debug.network()
    assert isinstance(net, pyds.ReteNetwork)
    assert isinstance(net.nodes, tuple) and isinstance(net.edges, tuple)
    assert all(isinstance(n, pyds.ReteNode) for n in net.nodes)
    assert all(isinstance(e, pyds.ReteEdge) for e in net.edges)
    assert {n.kind for n in net.nodes} == set(pyds.NodeKind)
    assert all(type(n.kind) is pyds.NodeKind for n in net.nodes)
    assert any(n.is_negative for n in net.nodes), "no NOT beta reported"
    ids = {n.id for n in net.nodes}
    assert net.edges and all(e.from_id in ids and e.to_id in ids for e in net.edges)
    assert hash(net) == hash(eng.debug.network())


def test_occupancy_is_none_unless_asked_for(run):
    eng, _, _ = run
    assert all(n.occupancy is None for n in eng.debug.network().nodes)


def test_a_rule_filter_keeps_that_rules_terminal(run):
    eng, _, _ = run
    whole = eng.debug.network()
    one = eng.debug.network(rule_filter="note_alarm")
    assert 0 < len(one.nodes) < len(whole.nodes)
    assert {n.label for n in one.nodes if n.kind is pyds.NodeKind.TERMINAL} == {"note_alarm"}


@pytest.mark.parametrize("reader", ["network", "refracted"])
def test_a_rule_filter_the_program_does_not_have_is_a_value_error(run, reader):
    eng, _, _ = run
    with pytest.raises(ValueError, match="nope"):
        getattr(eng.debug, reader)(rule_filter="nope")


def test_the_networks_options_are_keyword_only_and_typed(run):
    eng, _, _ = run
    with pytest.raises(TypeError):
        eng.debug.network("note_alarm")  # type: ignore[misc]  # positional
    with pytest.raises(TypeError):
        eng.debug.network(include_occupancy=1)  # type: ignore[arg-type]
    with pytest.raises(TypeError):
        eng.debug.network(rule_filter=1)  # type: ignore[arg-type]


# ---- the match trace -------------------------------------------------------


def test_a_match_trace_is_one_step_per_alpha_node(run):
    eng, sensor, _ = run
    steps = eng.debug.match_trace(sensor)
    assert steps and all(isinstance(s, pyds.TraceStep) for s in steps)
    assert all(s.node_kind is pyds.NodeKind.ALPHA for s in steps)
    assert all(type(s.result) is pyds.MatchResult for s in steps)
    assert pyds.MatchResult.PASSED in {s.result for s in steps}


# ---- refraction ------------------------------------------------------------


def test_each_fired_rule_is_refracted_with_the_facts_it_bound(run):
    # [NDBG.4.3]: terminals in ordinal order, each entry naming the facts the
    # author's patterns bound; the negated pattern binds none.
    eng, sensor, alarm = run
    assert eng.debug.refracted() == [
        pyds.RefractedActivation(
            rule_name="raise_alarm",
            reason="refraction",
            detail="fired, and not re-created since",
            fact_ids=(sensor,),
        ),
        pyds.RefractedActivation(
            rule_name="note_alarm",
            reason="refraction",
            detail="fired, and not re-created since",
            fact_ids=(alarm,),
        ),
    ]


def test_a_rule_filter_keeps_that_rules_entries(run):
    eng, _, _ = run
    assert [r.rule_name for r in eng.debug.refracted(rule_filter="note_alarm")] == ["note_alarm"]
