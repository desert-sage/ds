# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A nullable slot's fact-body field has presence ([RFCS.6.3]).

The field is written for every value, zero included, and omitted for null,
so a recorded null and the type's zero stay two states. libds's recorder
writes the asserted values, these read its recording through libds's reader
(`pyds.atoms`), and bodies A and B are libds's own vectors
(``runtime/tests/libds/impl/test_rfcs_fact.c``).
"""

import math

import pytest

import pyds
from pyds import AtomKind, atoms

_BODY_A = bytes(
    [
        0x08,
        0x03,  # f1 Int 3
        0x1A,
        0x00,
    ]
)  # f3 String "", present and empty
_BODY_B = bytes(
    [
        0x08,
        0x04,  # f1 Int 4
        0x11,
    ]
    + [0x00] * 8
)  # f2 +0.0, present

_MAYBE_DS = """
schema Maybe scope logical:
    id: Int key
    x: Float? mutable
    s: String? mutable
"""


def test_a_schema_reports_its_nullable_slots():
    eng = pyds.from_source(_MAYBE_DS)

    assert {s.name for s in eng.schemas["Maybe"].slots if s.nullable} == {"x", "s"}


def _record_maybe(tmp_path):
    """Assert bodies A's and B's values through libds's own recorder.

    Return the engine and the recording's atoms.
    """
    eng = pyds.from_source(_MAYBE_DS)
    eng.clock.mode = "mock"
    path = tmp_path / "maybe.dstrace"
    with eng.record(path):
        eng.assert_("Maybe", id=3, x=None, s="")
        eng.assert_("Maybe", id=4, x=0.0, s=None)
    return eng, list(atoms.iter_atoms(path.read_bytes()))


def test_libds_records_bodies_a_and_b(tmp_path):
    """Bodies A and B are recorded by libds as written.

    A null Float is absent and an empty String present (body A); a nullable
    zero is written and a null String absent (body B).
    """
    _, recorded = _record_maybe(tmp_path)
    bodies = [a.message().fact for a in recorded if a.kind is AtomKind.FACT_ASSERT]

    assert bodies == [_BODY_A, _BODY_B]


def test_libds_types_an_absent_field_as_null_and_a_present_zero_as_zero(tmp_path):
    eng, recorded = _record_maybe(tmp_path)
    facts = [
        eng.decode_fact_body("Maybe", a.message().fact)
        for a in recorded
        if a.kind is AtomKind.FACT_ASSERT
    ]

    assert facts == [{"id": 3, "x": None, "s": ""}, {"id": 4, "x": 0.0, "s": None}]
    assert math.copysign(1.0, facts[1]["x"]) == 1.0


def test_a_string_field_that_is_not_well_formed_utf8_is_a_malformed_body():
    """`Status.PARSE` from libds's decoder, as `decodeFactBody` gives it."""
    eng = pyds.from_source(_MAYBE_DS)

    with pytest.raises(pyds.InputError) as refused:
        eng.decode_fact_body("Maybe", bytes([0x08, 0x01, 0x1A, 0x02, 0x61, 0xFF]))
    assert refused.value.status is pyds.Status.PARSE


def test_rfcs_6_3__an_absent_json_field_is_a_malformed_body():
    """[RFCS.6.3]: `Status.PARSE`, as `decodeFactBody` gives it."""
    eng = pyds.from_source("""use default

schema Doc scope logical:
    k: Int key
    j: Json mutable
""")

    with pytest.raises(pyds.InputError) as refused:
        eng.decode_fact_body("Doc", bytes([0x08, 0x01]))
    assert refused.value.status is pyds.Status.PARSE


_DOCS_DS = """use default

schema Doc scope logical:
    k: Int key
    j: Json mutable

schema DocN scope logical:
    k: Int key
    j: Json? mutable

rule doc:
    Doc
->
    log info "doc"

rule doc_n:
    DocN
->
    log info "doc_n"
"""

_ROOT_NULL = bytes([0x08, 0x01, 0x12, 0x04]) + b"null"


def test_rfcs_6_3__a_root_null_json_field():
    """[RFCS.6.3]: `None` in `Json?`, `Status.PARSE` in `Json`.

    PATH PINNED: libds's decode_body, its last loop.
    """
    eng = pyds.from_source(_DOCS_DS)

    with pytest.raises(pyds.InputError) as refused:
        eng.decode_fact_body("Doc", _ROOT_NULL)
    assert refused.value.status is pyds.Status.PARSE
    assert eng.decode_fact_body("DocN", _ROOT_NULL) == {"k": 1, "j": None}


def _with_root_null(tmp_path, schema):
    """Record a `schema` fact holding `true`, and edit its text to `null` in place.

    No writer writes a root-null field. The rule reads no `j`, so the replay's
    compare has nothing to say about the edit.
    """
    eng = pyds.from_source(_DOCS_DS)
    eng.clock.mode = "mock"
    path = tmp_path / "doc.dstrace"
    with eng.record(path):
        eng.assert_(schema, k=1, j=True)
        eng.pump()
    stream = path.read_bytes()
    recorded = bytes([0x12, 0x04]) + b"true"
    assert stream.count(recorded) == 1
    return stream.replace(recorded, bytes([0x12, 0x04]) + b"null")


def test_rfcs_6_3__a_replay_of_a_root_null_in_a_json_slot_is_a_parse_refusal(tmp_path):
    """[RFCS.6.3]: the body is refused before the assert's door is reached.

    PATH PINNED: the FactAssert arm of rfcs/codec.c's replay -> decode_body's last
    loop, with DS_ERR_PARSE in place of the door's DS_ERR_SLOT_TYPE_MISMATCH.
    """
    stream = _with_root_null(tmp_path, "Doc")

    with pytest.raises(pyds.Error) as refused:
        pyds.from_source(_DOCS_DS).replay(stream)

    assert refused.value.status is pyds.Status.PARSE, refused.value


def test_rfcs_6_3__a_replay_of_a_root_null_in_a_json_opt_slot_holds_null(tmp_path):
    """[RFCS.6.3]: the replay reaches its end, and the fact holds `null`.

    PATH PINNED: the FactAssert arm of rfcs/codec.c's replay -> decode_body's last
    loop, which gives the assert DS_SLOT_NULL.
    """
    stream = _with_root_null(tmp_path, "DocN")
    reader = pyds.from_source(_DOCS_DS)

    res = reader.replay(stream)

    assert res.asserts == 1
    [fact] = reader.facts.of("DocN")
    assert fact.slots["j"] is None


def test_libds_s_slot_atoms_say_which_slots_are_nullable(tmp_path):
    """The announcement carries each slot's nullability ([RFCS.5.1]).

    So a reader with no artefact can tell an absent field (null) from an
    absent non-nullable one (its zero).
    """
    _, recorded = _record_maybe(tmp_path)
    slots = [a.message() for a in recorded if a.kind is AtomKind.SLOT]
    maybe = {s.slot_name: s.nullable for s in slots if s.schema_name == "Maybe"}

    assert maybe == {"id": False, "x": True, "s": True}
