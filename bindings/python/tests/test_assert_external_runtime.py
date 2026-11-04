# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Engine.assert_external (NCBK.10.4): a fact call argument's bytes go back in.

The FactExternal bytes a fact call argument hands out go back in, to another
engine, through libds's ds_engine_assert_external. How references
resolve (RFCS.23.7) is libds's and is tested there; these pin the binding:
what it takes, what it returns, and that a refusal raises with nothing
asserted.
"""

import pytest

import pyds

_SENDER = """
schema Reading scope logical:
    id: String key
    n: Int mutable

service svc.out:
    kwarg reading: Reading
    no response

rule send:
    Reading r
->
    call svc.out reading: r nocooldown
"""

_RECEIVER = """
schema Reading scope logical:
    id: String key
    n: Int mutable

rule seen:
    Reading
->
    log info "seen"
"""

# Reading's shape differs, so its schema_hash does (RFCS.23.3).
_RECEIVER_OTHER_SHAPE = _RECEIVER.replace("n: Int", "n: Float")

_RECEIVER_NO_READING = """
schema Other scope logical:
    id: String key

rule seen:
    Other
->
    log info "seen"
"""


def _sent():
    """Return the `reading` argument of one call: a pyds.EncodedFact."""
    eng = pyds.from_source(_SENDER)
    calls: list[dict] = []
    eng.set_call_callback(calls.append)
    eng.assert_("Reading", id="k", n=3)
    eng.pump()
    assert len(calls) == 1, calls
    return calls[0]["args"]["reading"]


def _readings(eng):
    return [(f.slots["id"], f.slots["n"]) for f in eng.facts.of("Reading")]


def test_an_encoded_fact_asserts_in_another_engine():
    rx = pyds.from_source(_RECEIVER)
    assert rx.assert_external(_sent()) is None
    assert _readings(rx) == [("k", 3)]


def test_its_bytes_alone_do_as_well():
    rx = pyds.from_source(_RECEIVER)
    rx.assert_external(bytearray(_sent().data))
    assert _readings(rx) == [("k", 3)]


@pytest.mark.parametrize(
    "program, family, status",
    [
        (_RECEIVER_OTHER_SHAPE, pyds.ExecutionError, pyds.Status.SCHEMA_HASH_MISMATCH),
        (_RECEIVER_NO_READING, pyds.InputError, pyds.Status.SCHEMA_UNKNOWN),
    ],
    ids=["schema-hash-mismatch", "schema-unknown"],
)
def test_a_refused_record_raises_and_asserts_nothing(program, family, status):
    rx = pyds.from_source(program)
    before = len(rx.facts)
    with pytest.raises(family) as refused:
        rx.assert_external(_sent())
    assert refused.value.status is status
    assert len(rx.facts) == before


def test_bytes_that_are_no_fact_external_are_a_parse_error():
    rx = pyds.from_source(_RECEIVER)
    with pytest.raises(pyds.InputError) as refused:
        rx.assert_external(b"\xff\xff\xff")
    assert refused.value.status is pyds.Status.PARSE
    assert len(rx.facts) == 0


@pytest.mark.parametrize("data", ["not bytes", 3, None])
def test_what_is_neither_bytes_nor_an_encoded_fact_is_a_type_error(data):
    rx = pyds.from_source(_RECEIVER)
    with pytest.raises(TypeError):
        rx.assert_external(data)


def test_a_closed_engine_refuses_with_value_error():
    """As every Engine method does, and as io refuses a closed file."""
    rx = pyds.from_source(_RECEIVER)
    rx.close()
    with pytest.raises(ValueError, match="operation on a closed Engine"):
        rx.assert_external(_sent())
