# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""pyds.atoms — libds's readers from Python, naming an atom by its field number.

The recording is written by libds's own recorder (`Engine.record`), so
every byte read here was written and is read by C: nothing in this file
decodes.
"""

import pytest

import pyds
from pyds import _atom_registry as reg
from pyds import atoms

_SRC = """
schema Rec scope logical:
    label: String key
    n: Int mutable
"""


@pytest.fixture
def recording(tmp_path):
    path = tmp_path / "run.rfcs"
    eng = pyds.from_source(_SRC)
    with eng.record(path):
        eng.assert_("Rec", label="a", n=1)
        eng.assert_("Rec", label="b", n=-2)
        eng.pump()
    return path.read_bytes()


def test_every_atom_frames_and_names_its_message(recording):
    found = list(atoms.iter_atoms(recording))
    assert found and found[0].kind == pyds.AtomKind.STREAM_HEADER
    offsets = [a.offset for a in found]
    assert offsets == sorted(offsets) and offsets[0] == 0
    assert found[-1].end == len(recording)
    for a in found:
        field = int(a.kind)
        assert atoms.message_name(field) == reg.MESSAGE_BY_FIELD[field]
        # The generic reader accepts every atom libds wrote.
        walk = atoms.visit_atom(field, a.body)
        assert walk[0][0] == "enter" and walk[-1][0] == "leave", field
        assert walk[0][5] == reg.MESSAGE_BY_FIELD[field]
    assert sum(1 for a in found if a.kind == pyds.AtomKind.FACT_ASSERT) == 2


def test_a_fact_assert_through_both_walks(recording):
    asserts = [a for a in atoms.iter_atoms(recording) if a.kind == pyds.AtomKind.FACT_ASSERT]
    field, body = int(asserts[0].kind), asserts[0].body

    wire = {f: (w, v) for f, w, v in atoms.wire_fields(body)}
    assert wire[2] == (2, b"Rec")  # schema_name, length-delimited

    typed = {t[1]: t for t in atoms.visit_atom(field, body) if t[4] == 0}
    assert typed["schema_name"][0] == "string"
    assert typed["schema_name"][6] == "Rec"
    assert typed["fact"][0] == "bytes"
    # Where the wire carries a varint, both walks agree on its value.
    for name, number in (("fact_id", 1), ("seq", 7)):
        if number in wire:
            assert wire[number] == (0, typed[name][6]), name


def test_a_cut_is_a_tail_only_to_the_partial_reader(recording):
    whole = list(atoms.iter_atoms(recording))
    last = whole[-1].offset
    cut = recording[:-1]

    found = list(atoms.iter_atoms(cut, partial=True))
    assert [a.offset for a in found] == [a.offset for a in whole[:-1]]

    with pytest.raises(pyds.Error, match=f"at byte {last}") as caught:
        list(atoms.iter_atoms(cut))
    assert caught.value.status is pyds.Status.PARSE


def test_refusals():
    # A number with no registry entry has no message.
    assert 2047 not in reg.REGISTRY
    assert atoms.message_name(2047) is None
    with pytest.raises(pyds.Error) as caught:
        atoms.wire_fields(b"\x00\x01")  # field 0 is no field
    assert caught.value.status is pyds.Status.PARSE
    with pytest.raises(pyds.Error) as caught:
        atoms.visit_atom(pyds.AtomKind.DIALECT_INFO, b"\x0a\x05")  # past the end
    assert isinstance(caught.value.status, pyds.Status)


@pytest.mark.parametrize("bad", [-1, 2**32])
def test_a_field_number_outside_uint32_is_an_overflow_error(bad):
    with pytest.raises(OverflowError):
        atoms.message_name(bad)
    with pytest.raises(OverflowError):
        atoms.visit_atom(bad, b"")


def test_a_field_number_is_an_int_not_a_name():
    with pytest.raises(TypeError):
        atoms.message_name("FactAssert")
