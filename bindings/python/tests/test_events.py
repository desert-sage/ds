# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""What an engine reports is a value: ``pyds.events``.

Each event is a frozen, slotted dataclass. It prints, compares and hashes by
value, takes ``match`` apart by field, and names its kind as ``ds_names.h``
does. Its class is named for that kind, so ``type_error`` is
``pyds.events.TypeError``, which ``pyds`` itself must not export.

``ActionCall.args`` and ``Metric.labels`` are each a plain ``dict``, the
event's own copy, so those two events copy, pickle and
convert with ``dataclasses.asdict`` as the rest do, and are not hashable.
"""

import builtins
import copy
import dataclasses
import json
import pickle

import pytest

import pyds
from pyds import events

_SOURCE = (
    'schema Trig scope logical:\n    v: Int key\n\nrule r:\n    Trig\n->\n    log info "hit"\n'
)


@pytest.fixture
def stream():
    """Every event one firing of ``r`` reports, in order."""
    with pyds.from_source(_SOURCE) as eng:
        eng.clock.mode = pyds.ClockMode.MOCK
        eng.clock.set(0)
        seen = []
        eng.on_event = seen.append
        eng.assert_("Trig", v=1)
        eng.pump()
    return seen


def test_every_event_is_a_frozen_value(stream):
    assert stream
    for ev in stream:
        assert dataclasses.is_dataclass(ev)
        with pytest.raises(dataclasses.FrozenInstanceError):
            ev.seq = -1


def test_kind_is_the_class_s_and_not_a_field(stream):
    for ev in stream:
        assert isinstance(ev.kind, pyds.EventKind)
        assert ev.kind is type(ev).kind
        assert "kind" not in {f.name for f in dataclasses.fields(ev)}


def test_the_stream_numbers_its_events_from_its_own_seq(stream):
    seqs = [ev.seq for ev in stream]
    assert seqs == sorted(seqs) and len(set(seqs)) == len(seqs)


def test_an_event_compares_and_hashes_by_value():
    a = events.RuleFireBegin(seq=3, clock_ns=0, rule_name="r", timetag=7)
    b = events.RuleFireBegin(seq=3, clock_ns=0, rule_name="r", timetag=7)
    c = events.RuleFireEnd(seq=3, clock_ns=0, rule_name="r", timetag=7)
    assert a == b and hash(a) == hash(b)
    assert a != c
    assert len({a, b, c}) == 2


def test_an_event_is_taken_apart_by_match(stream):
    fired = []
    for ev in stream:
        match ev:
            case events.ActionLog(level=pyds.LogLevel.INFO, message=message):
                fired.append(message)
    assert fired == ["hit"]


def test_its_repr_is_its_constructor_call():
    ev = events.FactAssert(seq=1, clock_ns=2, fact_id=pyds.FactId(3))
    assert repr(ev) == "FactAssert(seq=1, clock_ns=2, fact_id=FactId(3))"
    assert eval(repr(ev), {"FactAssert": events.FactAssert, "FactId": pyds.FactId}) == ev


_CALLING = (
    "service ha.switch.turn_on:\n"
    "    kwarg entity_id: String\n"
    "    no response\n"
    "\n"
    "schema Trig scope logical:\n"
    "    v: Int key\n"
    "\n"
    "rule r:\n"
    "    Trig\n"
    "->\n"
    '    call ha.switch.turn_on entity_id: "switch.fan" nocooldown as "fan-on"\n'
)


def test_a_delivered_call_copies_pickles_and_converts_to_json():
    with pyds.from_source(_CALLING) as eng:
        seen = []
        eng.on_event = seen.append
        eng.set_call_callback(lambda request: None)
        eng.assert_("Trig", v=1)
        eng.pump()
    (call,) = [ev for ev in seen if isinstance(ev, events.ActionCall)]
    assert type(call.args) is dict
    assert copy.deepcopy(call) == call
    assert pickle.loads(pickle.dumps(call)) == call
    assert json.loads(json.dumps(dataclasses.asdict(call)))["args"] == {"entity_id": "switch.fan"}


def _call() -> events.ActionCall:
    return events.ActionCall(
        seq=1, clock_ns=2, service="svc.x", correlation="c", args={"n": 1}, timetag=3, rule_name="r"
    )


def _metric() -> events.Metric:
    return events.Metric(name="m", kind=pyds.MetricKind.COUNTER, value=1.0, labels={"k": "v"})


@pytest.mark.parametrize("make", [_call, _metric], ids=["ActionCall", "Metric"])
def test_an_event_holding_a_dict_compares_by_value_and_is_not_hashable(make):
    assert make() == make()
    with pytest.raises(TypeError, match="unhashable"):
        hash(make())


def test_the_type_error_event_does_not_shadow_the_builtin():
    assert events.TypeError is not builtins.TypeError
    assert not issubclass(events.TypeError, BaseException)
    assert "TypeError" not in pyds.__all__
    assert not hasattr(pyds, "TypeError")
