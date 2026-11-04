# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`field_order.py`: its reading of `proto/`, and its walk shown firing.

A `field_order` vector passes when its writer is in order, so on the corpus
the walk only ever says "no problem". Each way it can say otherwise is shown
here on bytes built to break one rule, against the table read from the real
`proto/`: a walk never seen to fire is indistinguishable from a dead one.
"""
from __future__ import annotations

import json

import pytest

import field_order as fo

TAB = fo.table()


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _f(num: int, value: int | bytes) -> bytes:
    """One field: a varint for an int, length-delimited for bytes."""
    if isinstance(value, int):
        return _varint(num << 3) + _varint(value)
    return _varint(num << 3 | 2) + _varint(len(value)) + value


def _atom_number(msg: str) -> int:
    return next(n for n, (_, _, t) in TAB["Atom"].items() if t == msg)


def _stream(*atoms: tuple[str, bytes]) -> bytes:
    """A `Stream` of atoms, each (message name, body)."""
    return b"".join(_f(1, _f(_atom_number(msg), body)) for msg, body in atoms)


def _assert_body(*fields: bytes) -> bytes:
    return b"".join(fields)


# -- the table read from proto/ -------------------------------------------

def test_the_table_reaches_every_atom_from_the_root() -> None:
    assert TAB[fo.ROOT][1] == (1, True, "Atom")
    # Every member of the Atom oneof holds a message, so every atom body is
    # walked by its type.
    assert TAB["Atom"] and all(t and t != fo.FACT
                               for _, _, t in TAB["Atom"].values())


def test_rcts_1_2_19__the_dsc_container_is_walked_as_the_stream_is() -> None:
    """`dsc_field_order` walks a `.dsc` from `Dsc` ([RFCS.19.1]), which
    `test_conformance.m` reads from this table: it must be there, framed as
    `Stream` is, or every compiler vector fails for the table."""
    assert TAB["Dsc"] == TAB[fo.ROOT] == {1: (1, True, "Atom")}


def test_the_fact_bodies_are_typed_as_such() -> None:
    assert TAB["FactAssert"][3] == (3, False, fo.FACT)
    assert TAB["FactEmit"][3] == (3, False, fo.FACT)


def test_repeated_and_nested_fields_are_read() -> None:
    assert TAB["StreamHeader"][16][1] is True          # capabilities
    assert TAB["ExternalAssert"][1][2] == "FactExternal"
    assert TAB["FactExternal"][3] == (3, True, "Arg")


def test_a_nested_message_resolves_inside_its_parent() -> None:
    tab = fo.table_of({"a.proto": (
        "syntax = \"proto3\"; package x;\n"
        "message Stream { repeated Outer atoms = 1; }\n"
        "message FactAssert { bytes fact = 3; }\n"
        "message FactEmit { bytes fact = 3; }\n"
        "message Outer { message Inner { int32 v = 1; }\n"
        "  repeated Inner items = 2; Kind k = 3;\n"
        "  enum Kind { A = 0; }\n"
        "  oneof o { string s = 4; Inner i = 5; } }\n")})
    assert tab["Outer"][2] == (2, True, "Outer.Inner")
    assert tab["Outer"][3] == (3, False, "")
    assert tab["Outer"][5] == (5, False, "Outer.Inner")


@pytest.mark.parametrize("text", [
    "message Stream { map<string, int32> m = 1; }",
    "message Stream { Missing m = 1; }",
    "message Stream { int32 a = 1; int32 b = 1; }",
    "message Stream { int32 a = 1 }",
])
def test_a_proto_outside_the_subset_is_refused(text: str) -> None:
    with pytest.raises(fo.ProtoError):
        fo.table_of({"a.proto": text})


def test_the_table_json_is_what_test_behave_reads() -> None:
    data = json.loads(fo.table_json(TAB))
    assert data["root"] == "Stream"
    assert [3, False, "@fact"] in data["messages"]["FactAssert"]


# -- the walk, shown firing ---------------------------------------------------

def test_an_ascending_stream_has_no_problem() -> None:
    body = _assert_body(_f(1, 7), _f(2, b"Parcel"), _f(3, _f(1, 5) + _f(2, b"x")))
    assert fo.problems(_stream(("FactAssert", body)), TAB) == []


def test_a_field_before_a_lower_one_is_named() -> None:
    body = _assert_body(_f(2, b"Parcel"), _f(1, 7))
    out = fo.problems(_stream(("FactAssert", body)), TAB)
    assert out == ["atom 0 (FactAssert): field 1 after field 2"]


def test_a_field_that_is_not_repeated_twice_is_named() -> None:
    body = _assert_body(_f(1, 7), _f(1, 8))
    out = fo.problems(_stream(("FactAssert", body)), TAB)
    assert len(out) == 1 and "field 1 twice" in out[0]


def test_a_repeated_field_may_appear_again() -> None:
    head = _f(16, 1) + _f(16, 2)                      # capabilities, unpacked
    assert fo.problems(_stream(("StreamHeader", head)), TAB) == []


def test_a_fact_body_out_of_order_is_named() -> None:
    body = _assert_body(_f(1, 7), _f(3, _f(2, 5) + _f(1, 4)))
    out = fo.problems(_stream(("FactAssert", body)), TAB)
    assert out == ["atom 0 (FactAssert) > FactAssert.fact: slot field 1 "
                   "after field 2"]


def test_a_fact_body_slot_twice_is_named() -> None:
    body = _assert_body(_f(3, _f(1, 5) + _f(1, 6)))
    assert len(fo.problems(_stream(("FactAssert", body)), TAB)) == 1


def test_a_nested_message_out_of_order_is_named() -> None:
    ext = _f(3, _f(2, 1) + _f(1, b"a"))               # an Arg: kind before name
    out = fo.problems(_stream(("ExternalAssert", _f(1, ext))), TAB)
    assert out == ["atom 0 (ExternalAssert) > ExternalAssert.1 > "
                   "FactExternal.3: field 1 after field 2"]


def test_a_field_proto_does_not_declare_is_named() -> None:
    out = fo.problems(_stream(("FactAssert", _f(99, 1))), TAB)
    assert out == ["atom 0 (FactAssert): field 99 is not a field of "
                   "FactAssert"]


def test_a_truncated_body_is_named_not_skipped() -> None:
    out = fo.problems(_stream(("FactAssert", b"\x12\x09ab")), TAB)
    assert len(out) == 1 and "does not decode" in out[0]


def test_the_order_is_judged_per_message_not_across_atoms() -> None:
    # Each atom's fields start again from 1.
    s = _stream(("FactAssert", _f(2, b"P")), ("FactAssert", _f(1, 3)))
    assert fo.problems(s, TAB) == []


def test_swapping_two_fields_breaks_the_order_and_keeps_the_length() -> None:
    s = _stream(("FactAssert", _assert_body(_f(1, 7), _f(2, b"Parcel"))))
    probe = fo.swapped(s)
    assert probe is not None and len(probe) == len(s) and probe != s
    assert fo.problems(probe, TAB) == [
        "atom 0 (FactAssert): field 1 after field 2"]


def test_no_swap_when_no_body_has_two_fields() -> None:
    assert fo.swapped(_stream(("FactAssert", _f(1, 7)))) is None
