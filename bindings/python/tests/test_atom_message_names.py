# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`AtomKind` against `atom.proto`'s own descriptor.

Two independent readings of one fact. `AtomKind` is generated from
`proto/atom.proto`'s oneof; the descriptor
is protoc's reading of the same file. A disagreement means one of them names
the wrong message for a field number, or misses an atom.
"""

from pyds import AtomKind
from pyds.proto import atom_pb2

_BODY = atom_pb2.Atom.DESCRIPTOR.oneofs_by_name["body"]


def test_every_kind_is_the_oneof_field_of_that_number_and_message():
    by_number = {f.number: f.message_type.name for f in _BODY.fields}
    assert {k.value: k.message for k in AtomKind} == by_number


def test_a_kind_is_named_for_its_message_in_constant_spelling():
    for field in _BODY.fields:
        # The oneof field is the message in snake case,
        # and the member the same in upper case.
        assert AtomKind(field.number).name == field.name.upper()
