# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""What reaches the integrator: a `call`'s kwargs and a `cache` value.

A `Json` value reaches the peer, and the cache, as its value, never as `null`.
A kwarg with no value PREVENTS the call ([LNUL.11.1]); the `cache` row is the
other way, a `null` is stored.

An encoder that wrote `null` for a kind it does not list fails the Json tests,
and one that sends a `null` kwarg fails the null-kwarg test with a call made.
"""

import json

import pyds

_JSON_CALL = """
service svc.j:
    kwarg data: Json
    no response

schema E scope logical:
    id: Int key
    payload: Json mutable

rule send:
    E e
->
    call svc.j data: e.payload nocooldown
"""


def test_a_json_kwarg_reaches_the_peer_as_its_value():
    eng = pyds.from_source(_JSON_CALL)
    calls = []
    eng.set_call_callback(calls.append)
    eng.assert_("E", id=1, payload={"b": [1, 2], "a": True})
    eng.pump()
    assert len(calls) == 1, calls
    # The value, not `null`: its canonical JSON text, which pyds does not
    # parse (PYTHON_BINDING.md, OQ-2), as for a Json slot, as a JsonText.
    data = calls[0]["args"]["data"]
    assert type(data) is pyds.JsonText, calls[0]["args"]
    assert json.loads(data) == {"a": True, "b": [1, 2]}, data


# The kwarg reads a Json leaf. A `T?` value -- `p.txt::Float?` -- is refused
# at compile time in a `call` kwarg ([LNUL.5.1]), so the runtime's row
# of [LNUL.11.1] is reached by a value the compiler cannot see is absent: a
# leaf that is present and JSON `null`, which "reads as `null`" ([LNUL.8.4]).
_NULL_CALL = """
service svc.n:
    kwarg x: Float
    no response

schema E scope logical:
    id: Int key
    payload: Json mutable

rule send:
    E e
->
    call svc.n x: e.payload.x nocooldown
"""


def test_a_kwarg_with_no_value_prevents_the_call():
    """A kwarg with no value prevents the call ([LNUL.11.1]).

    "A bad kwarg prevents the call": a JSON-`null` leaf has no value, so
    nothing is called -- not a call carrying `null`.
    """
    eng = pyds.from_source(_NULL_CALL)
    calls = []
    eng.set_call_callback(calls.append)
    eng.assert_("E", id=1, payload={"x": None})
    eng.pump()
    assert calls == []


def test_a_kwarg_with_a_value_still_calls():
    """The control: the same rule, a leaf with a value."""
    eng = pyds.from_source(_NULL_CALL)
    calls = []
    eng.set_call_callback(calls.append)
    eng.assert_("E", id=1, payload={"x": 2.5})
    eng.pump()
    assert len(calls) == 1
    assert calls[0]["args"] == {"x": 2.5}


_CACHE = """
schema E scope logical:
    id: Int key
    payload: Json mutable
    txt: String mutable

rule keep_json:
    E e
->
    cache key: "j" value: e.payload

rule keep_absent:
    E e
->
    cache key: "n" value: e.txt::Float?
"""


def _cache_sets(eng):
    sets = {}
    eng.on_cache_set = lambda key, value_json, ttl_ns: sets.__setitem__(key, value_json)
    return sets


def test_a_json_cache_value_is_stored_as_its_text():
    eng = pyds.from_source(_CACHE)
    sets = _cache_sets(eng)
    eng.assert_("E", id=1, payload={"k": [1, None]}, txt="x")
    eng.pump()
    assert json.loads(sets["j"]) == {"k": [1, None]}, sets


def test_a_null_cache_value_is_stored_as_null():
    """A null cache value is stored as null ([LNUL.11.1]'s cache row).

    "Caching that a thing was absent is a valid thing to cache": the opposite
    of the call row, on purpose.
    """
    eng = pyds.from_source(_CACHE)
    sets = _cache_sets(eng)
    eng.assert_("E", id=1, payload={"k": 1}, txt="not a number")
    eng.pump()
    assert sets["n"] == "null", sets
