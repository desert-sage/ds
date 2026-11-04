# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A call's arguments reach Python typed.

libds hands the call callback, and the stream's action_call event, one typed
value per kwarg the call supplies, sorted by name. pyds gives them to Python as
`args`, a dict from kwarg name to a Python value of the matching type. A Json
value is its canonical JSON text, as a Json slot's is, and never parsed:
parsing would change integers past 64 bits, float spelling and duplicate keys
without saying so (PYTHON_BINDING.md, OQ-2). The text is a `pyds.JsonText`, a
str of its own type, so it is told from a String by isinstance. A fact
is a `pyds.EncodedFact`.
"""

import hashlib
import json

from google.protobuf import unknown_fields

import pyds
from pyds.proto import fact_external_pb2

_ALL_KINDS = """
schema Reading scope logical:
    id: String key
    n: Int mutable
    x: Float mutable
    ok: Bool mutable
    raw: Bytes mutable
    doc: Json mutable

service svc.all:
    kwarg n: Int
    kwarg x: Float
    kwarg s: String
    kwarg ok: Bool
    kwarg raw: Bytes
    kwarg doc: Json
    kwarg reading: Reading
    no response

rule send:
    Reading r
->
    call svc.all n: r.n x: r.x s: r.id ok: r.ok raw: r.raw doc: r.doc reading: r nocooldown
"""


def _one_call():
    eng = pyds.from_source(_ALL_KINDS)
    calls: list[dict] = []
    events: list[pyds.events.Event] = []
    eng.set_call_callback(calls.append)
    eng.on_event = events.append
    eng.assert_(
        "Reading", id="k", n=3, x=2.5, ok=True, raw=b"\x00\x01", doc={"a": [1, None], "b": "c"}
    )
    eng.pump()
    assert len(calls) == 1, calls
    issued = [e for e in events if isinstance(e, pyds.events.ActionCall)]
    assert len(issued) == 1, issued
    return calls[0], issued[0]


def test_each_kind_arrives_as_its_python_type():
    call, _ = _one_call()
    args = call["args"]
    assert list(args) == ["doc", "n", "ok", "raw", "reading", "s", "x"], args
    assert args["n"] == 3 and type(args["n"]) is int
    assert args["x"] == 2.5 and type(args["x"]) is float
    assert args["s"] == "k" and type(args["s"]) is str
    assert args["ok"] is True
    assert args["raw"] == b"\x00\x01"
    assert type(args["doc"]) is pyds.JsonText
    assert json.loads(args["doc"]) == {"a": [1, None], "b": "c"}


def test_a_json_argument_is_told_from_a_string_with_the_same_text():
    """A Json argument is a JsonText, and a String with the same text a plain str.

    libds and the recording keep Json and String apart, and so must pyds.
    Both are still str, and compare equal.
    """
    eng = pyds.from_source(_ALL_KINDS)
    calls: list[dict] = []
    eng.set_call_callback(calls.append)
    eng.assert_("Reading", id='{"a":1}', n=0, x=0.0, ok=False, raw=b"", doc={"a": 1})
    eng.pump()
    args = calls[0]["args"]
    assert isinstance(args["doc"], pyds.JsonText)
    assert not isinstance(args["s"], pyds.JsonText)
    assert isinstance(args["doc"], str) and isinstance(args["s"], str)
    assert json.loads(args["doc"]) == json.loads(args["s"])


def test_json_text_says_what_it_is_and_is_a_str():
    j = pyds.JsonText('{"a":1}')
    assert j == '{"a":1}' and hash(j) == hash('{"a":1}')
    assert repr(j) == """JsonText('{"a":1}')"""
    assert json.loads(j) == {"a": 1}


def test_a_json_argument_is_the_same_text_as_its_slot():
    eng = pyds.from_source(_ALL_KINDS)
    calls: list[dict] = []
    eng.set_call_callback(calls.append)
    fact = eng.assert_("Reading", id="k", n=3, x=2.5, ok=True, raw=b"", doc={"z": 1, "a": 2})
    eng.pump()
    slot = eng.facts[fact].slots["doc"]
    assert type(slot) is pyds.JsonText
    assert calls[0]["args"]["doc"] == slot


def test_a_fact_argument_is_an_encoded_fact():
    call, _ = _one_call()
    fact = call["args"]["reading"]
    assert isinstance(fact, pyds.EncodedFact)
    schema, asserted_at, data = fact  # a tuple, as os.stat_result is
    assert (schema, asserted_at, data) == (fact.schema, fact.asserted_at, fact.data)
    assert fact.schema == "Reading"
    assert isinstance(fact.asserted_at, int)
    assert isinstance(fact.data, bytes) and fact.data


def _fact_arg_on_mock_clock(wall_ns):
    """Return the `reading` argument of one call, on a mock clock.

    The mock clock's wall clock is `wall_ns`, or never set when that is None.
    """
    eng = pyds.from_source(_ALL_KINDS)
    eng.clock.mode = "mock"
    if wall_ns is not None:
        eng.clock.set_wall(wall_ns)
    calls: list[dict] = []
    eng.set_call_callback(calls.append)
    eng.assert_("Reading", id="k", n=3, x=2.5, ok=True, raw=b"", doc={})
    eng.pump()
    assert len(calls) == 1, calls
    return calls[0]["args"]["reading"]


def test_asserted_at_is_none_when_the_wall_clock_had_no_value():
    """RFCS.23.5: absent, not 0, which would read as 1970."""
    fact = _fact_arg_on_mock_clock(None)
    assert fact.asserted_at is None
    assert fact[1] is None


def test_asserted_at_is_the_wall_instant_the_fact_entered():
    wall_ns = 1_760_000_000 * 10**9
    assert _fact_arg_on_mock_clock(wall_ns).asserted_at == wall_ns


def test_the_stream_event_carries_the_same_arguments():
    call, event = _one_call()
    assert event.args == call["args"]
    # A call with no `as` carries the generated correlation (LCRS.3.1).
    assert event.correlation == call["correlation"] == "$send_c0_g0"


def test_a_fact_argument_decodes_as_the_fact():
    """A fact argument's bytes are the fact (RFCS.23).

    Its schema, its fields in declaration order with the asserted values, a
    schema_hash recomputed here from the SchemaShape ([RFCS.23.3], slots by
    name), and nothing else: a FactExternal carries no event_id
    ([RFCS.23.5]).
    """
    eng = pyds.from_source(_ALL_KINDS)
    calls: list[dict] = []
    eng.set_call_callback(calls.append)
    eng.assert_(
        "Reading", id="k", n=3, x=2.5, ok=True, raw=b"\x00\x01", doc={"a": [1, None], "b": "c"}
    )
    eng.pump()
    assert len(calls) == 1, calls

    fe = fact_external_pb2.FactExternal()
    fe.ParseFromString(calls[0]["args"]["reading"].data)
    assert fe.schema == "Reading"

    kind = fact_external_pb2.Kind
    assert [(f.name, f.kind) for f in fe.fields] == [
        ("id", kind.KIND_STRING),
        ("n", kind.KIND_INT),
        ("x", kind.KIND_FLOAT),
        ("ok", kind.KIND_BOOL),
        ("raw", kind.KIND_BYTES),
        ("doc", kind.KIND_JSON),
    ]
    f = {a.name: a for a in fe.fields}
    assert f["id"].string_value == "k"
    assert f["n"].int_value == 3
    assert f["x"].float_value == 2.5
    assert f["ok"].bool_value is True
    assert f["raw"].bytes_value == b"\x00\x01"
    assert json.loads(f["doc"].json_value) == {"a": [1, None], "b": "c"}

    shape = fact_external_pb2.SchemaShape(
        schema="Reading",
        slots=[
            fact_external_pb2.SlotShape(name=n, kind=k)
            for n, k in sorted(
                [
                    ("id", kind.KIND_STRING),
                    ("n", kind.KIND_INT),
                    ("x", kind.KIND_FLOAT),
                    ("ok", kind.KIND_BOOL),
                    ("raw", kind.KIND_BYTES),
                    ("doc", kind.KIND_JSON),
                ]
            )
        ],
    )
    assert fe.schema_hash == hashlib.sha256(shape.SerializeToString()).digest()

    # Field 4 (event_id) is gone from the proto, so an engine still writing
    # it would show up here as an unknown field rather than be dropped.
    # `unknown_fields.UnknownFieldSet`, not `Message.UnknownFields()`: the
    # pip runtime the images install no longer has the method.
    assert len(unknown_fields.UnknownFieldSet(fe)) == 0
