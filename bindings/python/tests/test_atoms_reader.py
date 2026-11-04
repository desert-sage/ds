# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`pyds.atoms`, libds's reader and framing (PYTHON_BINDING.md §13).

The byte vectors are `specs/conformance/PBF_FRAMING_VECTORS.json`'s, read here
rather than copied, so the corpus stays their one statement. Each answer under
test comes from libds: `iter_atoms` is `ds_pbf_next_atom` one step at a time,
`frame` is `ds_rfcs_pack_atom`, `band` / `disposition` / `container_of` are
`pbf_reader.h`'s, and `Engine.decode_fact_body` is `ds_rfcs_decode_fact_body`.
`Atom.message()` alone parses with protoc's generated class (OQ-6).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

import pyds
from pyds import AtomKind, atoms

_VECTORS = json.loads(
    (
        Path(__file__).resolve().parents[3] / "specs" / "conformance" / "PBF_FRAMING_VECTORS.json"
    ).read_text(encoding="utf-8")
)
_DECODE = _VECTORS["decode"]["vectors"]
_BAND = _VECTORS["band"]["vectors"]


def _ends_cleanly(row: dict) -> bool:
    """Say whether the vector's bytes end on an atom boundary, with nothing partial trailing."""
    data = bytes.fromhex(row["hex"])
    last = row["atoms"][-1]["next"] if row["atoms"] else 0
    return row["terminal"] == "eof" and last == len(data)


# --------------------------------------------------------------------------
#  §13.1 reading
# --------------------------------------------------------------------------


@pytest.mark.parametrize("row", _DECODE, ids=[r["name"] for r in _DECODE])
def test_iter_atoms_reads_each_decode_vector_as_libds_does(row):
    """With `partial=True` a trailing partial atom ends the reading ([RFCS.19.1], [RFCS.19.2]).

    Every complete atom before it is yielded; bytes no append could repair
    raise either way.
    """
    data = bytes.fromhex(row["hex"])
    if row["terminal"] == "malformed":
        with pytest.raises(pyds.InputError):
            list(atoms.iter_atoms(data, partial=True))
        return
    got = [(int(a.kind), len(a.body), a.end) for a in atoms.iter_atoms(data, partial=True)]
    assert got == [(a["field"], a["body_len"], a["next"]) for a in row["atoms"]]


@pytest.mark.parametrize("row", _DECODE, ids=[r["name"] for r in _DECODE])
def test_the_strict_reading_refuses_exactly_a_partial_tail(row):
    data = bytes.fromhex(row["hex"])
    if _ends_cleanly(row):
        assert [a.end for a in atoms.iter_atoms(data)] == [a["next"] for a in row["atoms"]]
    else:
        with pytest.raises(pyds.InputError):
            list(atoms.iter_atoms(data))


def test_an_atom_carries_where_its_frame_starts_and_ends():
    row = next(r for r in _DECODE if r["name"] == "two_atoms_dsc")
    got = list(atoms.iter_atoms(bytes.fromhex(row["hex"])))
    assert [(a.offset, a.end) for a in got] == [(0, 5), (5, 10)]


def test_a_known_number_is_its_kind_and_an_unknown_one_its_int():
    """[RFCS.16.3] leaves the set open to a reader."""
    row = next(r for r in _DECODE if r["name"] == "known_atom_after_unknown_skip")
    first, second = atoms.iter_atoms(bytes.fromhex(row["hex"]))
    assert type(first.kind) is int and first.kind == 2047
    assert second.kind is AtomKind.DSC_HEADER


def test_iter_atoms_is_lazy():
    """A malformed atom later in the buffer is not met until the iteration reaches it."""
    good = atoms.frame(AtomKind.DSC_HEADER, b"")
    it = atoms.iter_atoms(good + bytes.fromhex("ff00"))
    assert next(it).kind is AtomKind.DSC_HEADER
    with pytest.raises(pyds.InputError):
        next(it)


def test_an_atom_is_a_frozen_value_matched_by_shape():
    atom = next(atoms.iter_atoms(atoms.frame(AtomKind.FACT_RETRACT, b"\x08\x07")))
    match atom:
        case atoms.Atom(kind=AtomKind.FACT_RETRACT, body=body):
            assert body == b"\x08\x07"
        case _:
            pytest.fail(f"no match: {atom!r}")
    with pytest.raises(AttributeError):
        atom.body = b""  # type: ignore[misc]  # the assignment under test


def test_message_parses_the_body_with_its_generated_class():
    from pyds.proto import atom_pb2

    body_type = atom_pb2.Atom.DESCRIPTOR.fields_by_number[AtomKind.CLOCK_ADVANCE].message_type
    atom = next(atoms.iter_atoms(atoms.frame(AtomKind.CLOCK_ADVANCE, b"\x08\x05")))
    msg = atom.message()
    assert msg.DESCRIPTOR.full_name == body_type.full_name
    assert msg.seq == 5


def test_message_of_an_unknown_kind_is_a_lookup_error():
    row = next(r for r in _DECODE if r["name"] == "unknown_skip_band_atom")
    atom = next(atoms.iter_atoms(bytes.fromhex(row["hex"])))
    with pytest.raises(LookupError):
        atom.message()


# --------------------------------------------------------------------------
#  §13.2 framing
# --------------------------------------------------------------------------


def test_frame_writes_what_iter_atoms_reads():
    written = [
        (AtomKind.STREAM_HEADER, b""),
        (AtomKind.FACT_ASSERT, b"\x08\x01"),
        (AtomKind.CLOCK_ADVANCE, b"\xa5" * 300),
    ]
    data = b"".join(atoms.frame(kind, body) for kind, body in written)
    assert [(a.kind, a.body) for a in atoms.iter_atoms(data)] == written


def test_frame_matches_the_vectors_bytes():
    row = next(r for r in _DECODE if r["name"] == "dsc_header_with_body")
    assert atoms.frame(AtomKind.DSC_HEADER, b"\x08\x03") == bytes.fromhex(row["hex"])


def test_frame_refuses_a_number_with_no_registry_entry():
    free = next(n for n in range(1, 128) if n not in AtomKind)
    for bad in (0, free, 2048):
        with pytest.raises(ValueError):
            atoms.frame(bad, b"")
    with pytest.raises(OverflowError):
        atoms.frame(2**32, b"")
    with pytest.raises(OverflowError):
        atoms.frame(-1, b"")


# --------------------------------------------------------------------------
#  §13.3 bands, dispositions, containers
# --------------------------------------------------------------------------


@pytest.mark.parametrize("row", _BAND, ids=[str(r["field"]) for r in _BAND])
def test_band_disposition_and_allocation_answer_each_band_vector(row):
    """Each band vector's band, disposition and allocation ([RFCS.16.2], [RFCS.16.3], [RFCS.16.5]).

    Allocation is `field in AtomKind`; the blind disposition of a known atom
    is `skip`.
    """
    field = row["field"]
    assert atoms.band(field) is atoms.Band(row["band"])
    assert atoms.disposition(field) is atoms.Disposition(row["disposition"])
    assert (field in AtomKind) is row["known"]


@pytest.mark.parametrize("row", _DECODE, ids=[r["name"] for r in _DECODE])
def test_container_of_answers_each_decode_vector(row):
    """[RFCS.19.4]: the container's type is its first atom's number."""
    got = atoms.container_of(bytes.fromhex(row["hex"]))
    assert got is atoms.Container(row["container"])


def test_the_enums_are_the_vectors_words():
    assert {b.value for b in atoms.Band} == {r["band"] for r in _BAND}
    assert {d.value for d in atoms.Disposition} == {r["disposition"] for r in _BAND}
    assert {c.value for c in atoms.Container} == {r["container"] for r in _DECODE}


def test_a_field_number_out_of_range_is_an_overflow_error_never_wrapped():
    for bad in (-1, 2**32):
        with pytest.raises(OverflowError):
            atoms.band(bad)
        with pytest.raises(OverflowError):
            atoms.disposition(bad)


# --------------------------------------------------------------------------
#  §13.4 a recorded fact body
# --------------------------------------------------------------------------

_SRC = (
    "schema S scope logical:\n"
    "    k: Int key\n"
    "    name: String mutable\n"
    "    lit: Bool mutable\n"
    "    x: Float mutable\n"
)


def _recorded_fact_body(tmp_path, eng, **slots):
    path = tmp_path / "s.rfcs"
    with eng.record(path):
        eng.assert_("S", **slots)
    for atom in atoms.iter_atoms(path.read_bytes()):
        if atom.kind is AtomKind.FACT_ASSERT:
            msg = atom.message()
            return msg.schema_name, msg.fact
    pytest.fail("the recording holds no FactAssert")


def test_decode_fact_body_reads_a_recorded_fact_as_the_engine_holds_it(tmp_path):
    eng = pyds.from_source(_SRC)
    slots = {"k": 7, "name": "kitchen", "lit": True, "x": 2.5}
    schema, body = _recorded_fact_body(tmp_path, eng, **slots)
    assert schema == "S"
    assert eng.decode_fact_body(schema, body) == slots
    (fact,) = eng.facts.values()
    assert eng.decode_fact_body(schema, body) == dict(fact.slots)


def test_decode_fact_body_of_a_schema_the_engine_lacks_is_a_key_error(tmp_path):
    eng = pyds.from_source(_SRC)
    _, body = _recorded_fact_body(tmp_path, eng, k=1, name="a", lit=False, x=0.0)
    with pytest.raises(KeyError):
        eng.decode_fact_body("NoSuchSchema", body)


def test_decode_fact_body_refuses_a_schema_with_a_fact_ref_slot():
    """A body with a fact-ref slot cannot be decoded without its stream's map ([RFCS.6.3]).

    A recorded handle means something only to the stream's own reader.
    """
    eng = pyds.from_source(
        "schema Owner scope logical:\n    id: Int key\n\n"
        "schema Tag scope ttl 1_h:\n    n: Int\n    owner: Owner\n"
    )
    with pytest.raises(ValueError):
        eng.decode_fact_body("Tag", b"")
