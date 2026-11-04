# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The status matcher and the artefact edits in `runner.py`, pinned in both
directions.

A `ds_status_t` is a number ([LERR.8.1]), read from the exception's `status`,
never from its text.
"""
from __future__ import annotations

from dsc_seal import (add_compiled_code, add_slot_schema_ref, seal,
                      sha256_offset)
from pyds.errors import _error_for
from runner import (_late_start, _raised_status, _replay_cache_cap_misplaced,
                    _tampered, _timetag_offset, _timetag_offset_misplaced)
from stream_edit import (UNALLOCATED_CAPABILITY, UNCARRIED_ID, mutate,
                         offset_timetags)


class TestRaisedStatus:

    def test_the_status_is_found(self) -> None:
        assert _raised_status(_error_for(-216, "NaN Float rejected"), "-216")

    def test_a_different_status_is_not_found(self) -> None:
        assert not _raised_status(_error_for(-216, "NaN Float rejected"), "-206")

    def test_a_strict_prefix_does_not_satisfy_the_longer_status(self) -> None:
        assert not _raised_status(_error_for(-216, "NaN Float rejected"), "-21")

    def test_a_number_in_the_text_is_not_the_status(self) -> None:
        # Neither a bracketed number nor a loose one in the message is the
        # status; only the attribute is.
        assert not _raised_status(_error_for(-206, "slot 216 is out of range"), "216")
        assert not _raised_status(RuntimeError("[-216] looks like a status"), "-216")

    def test_a_status_outside_the_dictionary_is_matched_by_number(self) -> None:
        assert _raised_status(_error_for(-10001, "the integrator's own"), "-10001")

    def test_an_exception_with_no_status_matches_nothing(self) -> None:
        assert not _raised_status(TypeError("slot `k`: expected int"), "-104")
        assert not _raised_status(_error_for(-1, "x").__class__(None, "x"), "-1")

    def test_a_named_code_is_not_a_status(self) -> None:
        assert not _raised_status(
            _error_for(-100, "DS_VALIDATE_NAME_COLLISION"),
            "DS_VALIDATE_NAME_COLLISION")


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _atom(field: int, body: bytes) -> bytes:
    inner = _varint((field << 3) | 2) + _varint(len(body)) + body
    return b"\x0a" + _varint(len(inner)) + inner


# A sealed artefact of two atoms: a DscHeader (263) whose only field is the
# 32-byte `dsc_sha256` (field 7), then a Slot (257) whose body is one field.
_SLOT_BODY = b"\x0a\x01T"
_ART = seal(_atom(263, b"\x3a\x20" + bytes(32)) + _atom(257, _SLOT_BODY))


def _diff(a: bytes, b: bytes) -> list[int]:
    return [i for i, (x, y) in enumerate(zip(a, b)) if x != y]


# @spec [RCTS.1.2.21]
class TestTampered:
    """`runtime_error`'s `tamper` ([RCTS.1.2.21]; [RDSC.3.6], [RDSC.9.5],
    [RDSC.9.7])."""

    def test_the_fixture_is_sealed(self) -> None:
        assert sha256_offset(_ART) is not None and seal(_ART) == _ART

    def test_a_string_flips_one_byte_and_does_not_reseal(self) -> None:
        out = _tampered(_ART, "last_byte")
        assert _diff(_ART, out) == [len(_ART) - 1]
        assert seal(out) != out

    def test_truncate_tail_cuts_the_tail_and_reseals(self) -> None:
        # Fails on: a truncation left unsealed, which every runtime refuses
        # for the hash before it reaches the cut atom.
        out = _tampered(_ART, {"truncate_tail": 1})
        assert len(out) == len(_ART) - 1 and out == seal(_ART[:-1])
        assert out != _ART[:-1]                     # the hash was rewritten

    def test_truncate_tail_must_leave_bytes_and_cut_some(self) -> None:
        assert _tampered(_ART, {"truncate_tail": 0}) is None
        assert _tampered(_ART, {"truncate_tail": len(_ART)}) is None

    def test_bad_wire_type_breaks_the_first_tag_of_that_atom_and_reseals(self) -> None:
        # Fails on: an edit outside the body, which breaks the frame rather
        # than the body, or a missing re-seal.
        out = _tampered(_ART, {"bad_wire_type": 257})
        body = len(_ART) - len(_SLOT_BODY)
        hash_at = sha256_offset(_ART)
        changed = [i for i in _diff(_ART, out)
                   if not hash_at <= i < hash_at + 32]
        assert changed == [body]
        assert out[body] & 0x07 == 0x07 and out[body] >> 3 == _SLOT_BODY[0] >> 3
        assert seal(out) == out

    def test_bad_wire_type_on_an_absent_atom_has_no_site(self) -> None:
        assert _tampered(_ART, {"bad_wire_type": 258}) is None

    def test_truncate_to_keeps_the_first_n_bytes(self) -> None:
        # Fails on: the wrong end kept, an empty artefact taken as no site,
        # or a cut that leaves the header whole left unsealed.
        assert _tampered(_ART, {"truncate_to": 0}) == b""
        assert _tampered(_ART, {"truncate_to": 1}) == _ART[:1]
        cut = len(_ART) - 1
        assert _tampered(_ART, {"truncate_to": cut}) == seal(_ART[:cut])

    def test_truncate_to_must_cut_some(self) -> None:
        assert _tampered(_ART, {"truncate_to": len(_ART)}) is None
        assert _tampered(_ART, {"truncate_to": -1}) is None
        assert _tampered(_ART, {"truncate_to": True}) is None

    def test_drop_atom_removes_one_whole_frame(self) -> None:
        # Fails on: the header left in, a frame cut short, or the wrong atom
        # counted from.
        slot = _atom(257, _SLOT_BODY)
        assert _tampered(_ART, {"drop_atom": 0}) == slot
        assert _tampered(_ART, {"drop_atom": 1}) == seal(_ART[:-len(slot)])
        assert _tampered(_ART, {"drop_atom": 2}) is None
        assert _tampered(_ART, {"drop_atom": -1}) is None
        assert _tampered(_ART, {"drop_atom": "0"}) is None

    def test_insert_bytes_puts_octets_before_an_atom_and_reseals(self) -> None:
        # Fails on: the octets put after the atom rather than before it, or
        # a header the walk still reaches left unsealed, which every runtime
        # would refuse for its hash before it met the octets.
        slot = _atom(257, _SLOT_BODY)
        head = _ART[:-len(slot)]
        frame = _atom(2047, b"")
        before = _tampered(_ART, {"insert_bytes": {"at": 0, "hex": frame.hex()}})
        assert before == seal(frame + _ART) and before != frame + _ART
        middle = _tampered(_ART, {"insert_bytes": {"at": 1, "hex": "0a00"}})
        assert middle == seal(head + b"\x0a\x00" + slot)
        after = _tampered(_ART, {"insert_bytes": {"at": 2, "hex": "00ff"}})
        assert after == seal(_ART + b"\x00\xff") and after != _ART + b"\x00\xff"

    def test_octets_the_walk_cannot_pass_leave_nothing_to_seal(self) -> None:
        # [RCTS.1.2.21]: the hash is the first DscHeader's that the walk
        # reaches; a frame the walk stops at hides the header behind it.
        assert _tampered(_ART, {"insert_bytes": {"at": 0, "hex": "0b00"}}) \
            == b"\x0b\x00" + _ART

    def test_insert_bytes_without_a_site_or_off_its_shape(self) -> None:
        for arg in ({"at": 3, "hex": "00"}, {"at": -1, "hex": "00"},
                    {"at": 0, "hex": ""}, {"at": 0, "hex": "0"},
                    {"at": 0, "hex": "0A"}, {"at": 0, "hex": "zz"},
                    {"at": True, "hex": "00"}, {"at": 0}, {"hex": "00"},
                    {"at": 0, "hex": "00", "x": 1}):
            assert _tampered(_ART, {"insert_bytes": arg}) is None, arg
        # Frames that do not walk to the end leave "after the last" unsaid.
        assert _tampered(_ART + b"\x00",
                         {"insert_bytes": {"at": 2, "hex": "00"}}) is None

    def test_the_seal_finds_the_header_wherever_the_walk_reaches_it(self) -> None:
        # Fails on: a seal that reads the first atom alone, which leaves a
        # displaced header's hash stale.
        frame = _atom(2047, b"")
        assert sha256_offset(frame + _ART) == sha256_offset(_ART) + len(frame)
        slot = _atom(257, _SLOT_BODY)
        assert sha256_offset(slot) is None
        assert seal(b"") == b"" and seal(slot) == slot

    def test_an_unknown_or_ambiguous_edit_has_no_site(self) -> None:
        assert _tampered(_ART, {"cut": 1}) is None
        assert _tampered(_ART, {"truncate_tail": 1, "bad_wire_type": 257}) is None
        assert _tampered(_ART, {"truncate_tail": True}) is None
        assert _tampered(_ART, "first_byte") is None
        assert _tampered(_ART, {"truncate_tail": "1"}) is None
        assert _tampered(_ART, {"drop_schema_group": 1}) is None


def _str(field: int, text: str) -> bytes:
    raw = text.encode()
    return _varint((field << 3) | 2) + _varint(len(raw)) + raw


def _int(field: int, value: int) -> bytes:
    return _varint(field << 3) + _varint(value)


_HEADER = _atom(263, b"\x3a\x20" + bytes(32))


def _group(name: str) -> bytes:
    """A schema group ([RDSC.8.1]): SchemaLogical (299), a Slot (257),
    SchemaSource (302), SchemaDef (256) naming `name`."""
    return (_atom(299, _str(1, name)) + _atom(257, _SLOT_BODY)
            + _atom(302, _str(1, name)) + _atom(256, _str(1, name)))


# @spec [RCTS.1.2.21]
class TestStructuralTampers:
    """`drop_schema_group` ([RDSC.8.7]) and `drop_terminal_parent`
    ([RDSC.11.1]): each removes whole atoms and re-seals ([RCTS.1.2.21])."""

    def test_drop_schema_group_removes_the_named_group_only(self) -> None:
        # Fails on: a cut that keeps the lifecycle atom, or takes the other
        # group's atoms with it.
        alpha = _atom(268, _str(2, "A"))
        art = seal(_HEADER + _group("A") + _group("B") + alpha)
        out = _tampered(art, {"drop_schema_group": "A"})
        assert out == seal(_HEADER + _group("B") + alpha)

    def test_drop_schema_group_of_an_undeclared_schema_has_no_site(self) -> None:
        art = seal(_HEADER + _group("A"))
        assert _tampered(art, {"drop_schema_group": "Z"}) is None

    def test_drop_terminal_parent_removes_the_beta_the_terminal_names(self) -> None:
        # Fails on: removing the first BetaNode rather than the named one.
        beta1 = _atom(269, _int(1, 1) + _int(2, 1))
        beta2 = _atom(269, _int(1, 2) + _int(2, 1) + _int(3, 1))
        term = _atom(270, _int(1, 3) + _int(2, 2) + _str(3, "r"))
        art = seal(_HEADER + beta1 + beta2 + term)
        out = _tampered(art, {"drop_terminal_parent": "r"})
        assert out == seal(_HEADER + beta1 + term)

    def test_drop_terminal_parent_without_a_site(self) -> None:
        beta = _atom(269, _int(1, 1))
        term = _atom(270, _int(1, 3) + _int(2, 1) + _str(3, "r"))
        orphan = _atom(270, _int(1, 4) + _str(3, "q"))     # no parent field
        art = seal(_HEADER + beta + term + orphan)
        assert _tampered(art, {"drop_terminal_parent": "x"}) is None
        assert _tampered(art, {"drop_terminal_parent": "q"}) is None
        gone = seal(_HEADER + term)                         # names beta 1, absent
        assert _tampered(gone, {"drop_terminal_parent": "r"}) is None


def _broken(field: int, body: bytes) -> bytes:
    """Atom `field` with its body's first byte given wire type 7, as
    `bad_wire_type` leaves it."""
    return _atom(field, bytes([(body[0] & 0xF8) | 0x07]) + body[1:])


# @spec [RCTS.1.2.21]
class TestTamperList:
    """A `tamper` list ([RCTS.1.2.21]): two or more structural edits,
    each made to the artefact the ones before it left, sealed once."""

    _ALPHA = _atom(268, _str(2, "A"))
    _BETA_BODY = _int(1, 1) + _int(2, 1)

    def test_a_list_makes_every_edit_and_seals_once(self) -> None:
        # Fails on: an edit skipped, or the result left unsealed.
        art = seal(_HEADER + _group("A") + _group("B") + self._ALPHA
                   + _atom(269, self._BETA_BODY))
        out = _tampered(art, [{"drop_schema_group": "A"},
                              {"bad_wire_type": 269}])
        assert out == seal(_HEADER + _group("B") + self._ALPHA
                           + _broken(269, self._BETA_BODY))

    def test_each_edit_is_made_to_what_the_ones_before_it_left(self) -> None:
        # Fails on: every member made to the compiled artefact. Dropped
        # first, A's group is gone and the first SchemaDef left is B's;
        # broken first, A's SchemaDef names nothing, so A has no group.
        art = seal(_HEADER + _group("A") + _group("B") + self._ALPHA)
        out = _tampered(art, [{"drop_schema_group": "A"},
                              {"bad_wire_type": 256}])
        b_group = _group("B")
        b_def = _atom(256, _str(1, "B"))
        assert b_group.endswith(b_def)
        assert out == seal(_HEADER + b_group[:-len(b_def)]
                           + _broken(256, _str(1, "B")) + self._ALPHA)
        assert _tampered(art, [{"bad_wire_type": 256},
                               {"drop_schema_group": "A"}]) is None

    def test_a_list_that_is_no_member_is_refused(self) -> None:
        # Fails on: a list of one taken for its object, a byte flip or
        # `drop_call_operand` accepted inside a list, or a member with no
        # site passed over.
        art = seal(_HEADER + _group("A") + _group("B") + self._ALPHA
                   + _atom(269, self._BETA_BODY))
        drop, wire = {"drop_schema_group": "A"}, {"bad_wire_type": 269}
        for tamper in ([], [drop], ["last_byte", wire], [drop, "last_byte"],
                       [[drop, wire], wire], [{"drop_call_operand": "r"}, wire],
                       [drop, {"drop_call_operand": "r"}],
                       [{"drop_schema_group": "Z"}, wire],
                       [drop, {"bad_wire_type": 258}],
                       [{"truncate_tail": 1, "bad_wire_type": 269}, drop]):
            assert _tampered(art, tamper) is None, tamper


def _msg(field: int, body: bytes) -> bytes:
    return _varint((field << 3) | 2) + _varint(len(body)) + body


def _call(*args: bytes) -> bytes:
    """An Action (term.proto) of kind ACTION_CALL, absent as proto3 writes a
    zero, whose `expr` (2) is a `call` (Expr 8): CallExpr `args` (2) then
    `op` (3) = 47, FN_LOG."""
    return _msg(2, _msg(8, b"".join(_msg(2, a) for a in args) + _int(3, 47)))


_LIT_INT = _int(1, 1)                       # Expr.lit_int = 1
_LIT_STR = _str(3, "x")                     # Expr.lit_str = "x"
_ASSERT = _int(1, 1) + _str(3, "Out")       # ACTION_ASSERT of `Out`


def _term(rule: str, *actions: bytes) -> bytes:
    return _atom(270, _int(1, 3) + _int(2, 1) + _str(3, rule)
                 + b"".join(_msg(6, a) for a in actions))


# @spec [RCTS.1.2.21]
class TestDropCallOperand:
    """`drop_call_operand` ([RDSC.4a.9.3]): rule R's first call action loses
    its last operand, the frames are rewritten, and the artefact re-sealed."""

    def test_the_first_call_loses_its_last_operand_only(self) -> None:
        # Fails on: the first operand dropped instead of the last, the assert
        # action or the second call edited, a frame length left stale, or a
        # missing re-seal.
        art = seal(_HEADER + _term("r", _ASSERT, _call(_LIT_INT, _LIT_STR),
                                   _call(_LIT_INT, _LIT_STR)))
        out = _tampered(art, {"drop_call_operand": "r"})
        assert out == seal(_HEADER + _term("r", _ASSERT, _call(_LIT_INT),
                                           _call(_LIT_INT, _LIT_STR)))
        assert seal(out) == out

    def test_only_the_named_rule_is_edited(self) -> None:
        other = _term("q", _call(_LIT_INT, _LIT_STR))
        art = seal(_HEADER + other + _term("r", _call(_LIT_INT, _LIT_STR)))
        out = _tampered(art, {"drop_call_operand": "r"})
        assert out == seal(_HEADER + other + _term("r", _call(_LIT_INT)))

    def test_without_a_site(self) -> None:
        # Fails on: a pass that edits nothing and reports success, which a
        # vector would read as the runtime admitting a short call.
        for art in (seal(_HEADER + _term("q", _call(_LIT_INT))),   # no `r`
                    seal(_HEADER + _term("r", _ASSERT)),           # no call
                    seal(_HEADER + _term("r", _call())),           # no operand
                    seal(_HEADER + _term("r", _call(_LIT_INT))
                         + _term("r", _call(_LIT_INT)))):          # two `r`s
            assert _tampered(art, {"drop_call_operand": "r"}) is None

    def test_the_argument_is_a_rule_name(self) -> None:
        art = seal(_HEADER + _term("r", _call(_LIT_INT)))
        assert _tampered(art, {"drop_call_operand": 1}) is None


def _wrap(expr: bytes) -> bytes:
    """`expr` as the operand of a `not`: Expr.unop (7), UnopExpr.operand (2),
    the op UNOP_NOT written absent."""
    return _msg(7, _msg(2, expr))


_CALL_EXPR = _msg(8, _msg(2, _LIT_INT) + _int(3, 47))   # the Expr `_call` holds
_ASSIGN = _int(1, 0) + _msg(2, _LIT_INT)                # SlotAssign 0 := 1
_ASSERT_ASSIGNING = _ASSERT + _msg(4, _ASSIGN) + _msg(4, _ASSIGN)


# @spec [RCTS.1.2.21]
class TestExpressionShapes:
    """[RDSC.11.3]'s four load refusals: each edits one action of rule
    R's terminal, re-frames it and re-seals ([RCTS.1.2.21])."""

    def test_drop_action_expr_empties_the_first_call_only(self) -> None:
        # Fails on: the assert or the second call edited, the `expr` left in
        # place, or a stale frame.
        art = seal(_HEADER + _term("r", _ASSERT, _call(_LIT_INT), _call(_LIT_INT)))
        out = _tampered(art, {"drop_action_expr": "r"})
        assert out == seal(_HEADER + _term("r", _ASSERT, b"", _call(_LIT_INT)))

    def test_clear_action_expr_leaves_an_expr_of_no_kind(self) -> None:
        # Fails on: the `expr` removed rather than emptied, which is the
        # third shape and not this one.
        art = seal(_HEADER + _term("r", _call(_LIT_INT)))
        out = _tampered(art, {"clear_action_expr": "r"})
        assert out == seal(_HEADER + _term("r", _msg(2, b"")))

    def test_drop_assign_expr_empties_the_first_assignment_only(self) -> None:
        # Fails on: the slot index dropped too, or the second assignment
        # edited.
        art = seal(_HEADER + _term("r", _call(_LIT_INT), _ASSERT_ASSIGNING))
        out = _tampered(art, {"drop_assign_expr": "r"})
        want = _ASSERT + _msg(4, _int(1, 0)) + _msg(4, _ASSIGN)
        assert out == seal(_HEADER + _term("r", _call(_LIT_INT), want))

    def test_nest_action_expr_wraps_the_whole_expr_levels_times(self) -> None:
        # Fails on: a level too few or too many, which moves the boundary
        # a vector sits on, or the wrap put inside the call.
        art = seal(_HEADER + _term("r", _call(_LIT_INT)))
        out = _tampered(art, {"nest_action_expr": {"rule": "r", "levels": 2}})
        assert out == seal(_HEADER + _term(
            "r", _msg(2, _wrap(_wrap(_CALL_EXPR)))))

    def test_without_a_site(self) -> None:
        # Fails on: a pass that edits nothing and reports success.
        no_call = seal(_HEADER + _term("r", _ASSERT_ASSIGNING))
        no_assign = seal(_HEADER + _term("r", _ASSERT, _call(_LIT_INT)))
        no_expr = seal(_HEADER + _term("r", b""))
        twice = seal(_HEADER + _term("r", _call(_LIT_INT))
                     + _term("r", _call(_LIT_INT)))
        for art, tamper in (
                (no_call, {"drop_action_expr": "r"}),
                (no_call, {"clear_action_expr": "r"}),
                (no_call, {"nest_action_expr": {"rule": "r", "levels": 1}}),
                (no_assign, {"drop_assign_expr": "r"}),
                (no_expr, {"drop_action_expr": "r"}),
                (no_expr, {"clear_action_expr": "r"}),
                (twice, {"drop_action_expr": "r"}),
                (no_assign, {"drop_action_expr": "q"})):
            assert _tampered(art, tamper) is None, tamper

    def test_an_argument_of_another_shape_is_refused(self) -> None:
        art = seal(_HEADER + _term("r", _call(_LIT_INT)))
        for tamper in ({"drop_action_expr": 1}, {"clear_action_expr": None},
                       {"drop_assign_expr": ["r"]},
                       {"nest_action_expr": "r"},
                       {"nest_action_expr": {"rule": "r"}},
                       {"nest_action_expr": {"rule": "r", "levels": 0}},
                       {"nest_action_expr": {"rule": "r", "levels": True}},
                       {"nest_action_expr": {"rule": "r", "levels": 1, "x": 1}},
                       {"drop_call_operand": {"rule": "r", "levels": 1}}):
            assert _tampered(art, tamper) is None, tamper


def _call_op(op: int, *args: bytes) -> bytes:
    """`_call`'s action with its CallExpr's `op` written as `op`."""
    return _msg(2, _msg(8, b"".join(_msg(2, a) for a in args) + _int(3, op)))


def _assigning(op: int) -> bytes:
    """An ACTION_ASSERT whose first SlotAssign's `expr` is a call of `op` on
    one operand, then a second SlotAssign of a literal."""
    call = _msg(8, _msg(2, _LIT_INT) + _int(3, op))
    return (_ASSERT + _msg(4, _int(1, 0) + _msg(2, call))
            + _msg(4, _ASSIGN))


# @spec [RCTS.1.2.21]
class TestSetOp:
    """`set_action_op` and `set_assign_op` ([RDSC.4a.9.3]): one
    CallExpr's `op` (field 3) becomes N at an action's `expr` or inside an
    assignment's expression, re-framed and re-sealed ([RCTS.1.2.21])."""

    def test_set_action_op_rewrites_the_first_call_action_only(self) -> None:
        # Fails on: the assert or the second call edited, the operands moved,
        # a stale frame (109 is one byte, 1000 two), or a missing re-seal.
        art = seal(_HEADER + _term("r", _assigning(1), _call(_LIT_INT),
                                   _call(_LIT_INT)))
        for op in (109, 1000):
            out = _tampered(art, {"set_action_op": {"rule": "r", "op": op}})
            assert out == seal(_HEADER + _term(
                "r", _assigning(1), _call_op(op, _LIT_INT), _call(_LIT_INT))), op

    def test_set_assign_op_rewrites_the_first_assignment_s_call_only(self) -> None:
        # Fails on: the call action edited instead, or the second assignment.
        art = seal(_HEADER + _term("r", _call(_LIT_INT), _assigning(1)))
        out = _tampered(art, {"set_assign_op": {"rule": "r", "op": 109}})
        assert out == seal(_HEADER + _term("r", _call(_LIT_INT),
                                           _assigning(109)))

    def test_without_a_site(self) -> None:
        # Fails on: a pass that edits nothing and reports success, which a
        # vector would read as the runtime refusing an unedited artefact.
        literal = seal(_HEADER + _term("r", _msg(2, _LIT_INT)))   # expr no call
        no_op = seal(_HEADER + _term("r", _msg(2, _msg(8, _msg(2, _LIT_INT)))))
        plain = seal(_HEADER + _term("r", _ASSERT_ASSIGNING))      # literal assigns
        no_assign = seal(_HEADER + _term("r", _ASSERT, _call(_LIT_INT)))
        for art, tamper in (
                (literal, "set_action_op"), (no_op, "set_action_op"),
                (plain, "set_action_op"), (plain, "set_assign_op"),
                (no_assign, "set_assign_op")):
            assert _tampered(art, {tamper: {"rule": "r", "op": 109}}) is None, \
                (tamper, art)
        art = seal(_HEADER + _term("r", _call(_LIT_INT)))
        assert _tampered(art, {"set_action_op": {"rule": "q", "op": 109}}) is None

    def test_an_argument_of_another_shape_is_refused(self) -> None:
        art = seal(_HEADER + _term("r", _call(_LIT_INT), _assigning(1)))
        for name in ("set_action_op", "set_assign_op"):
            for arg in ({"rule": "r"}, {"op": 109}, {"rule": "r", "op": -1},
                        {"rule": "r", "op": True}, {"rule": "r", "op": "109"},
                        {"rule": 1, "op": 109},
                        {"rule": "r", "op": 109, "x": 1}, "r", 109):
                assert _tampered(art, {name: arg}) is None, (name, arg)


# An AlphaNode (268): node_id 5, schema_name "S", two AlphaTests, the first
# an EQ on slot 0 against literal int 1 (kind EQ and op EQ written absent),
# the second a CMP (kind 1) on slot 1, op GT (3), literal int 2.
_TEST_EQ = _int(2, 0) + _msg(4, _int(1, 1))
_TEST_CMP = _int(1, 1) + _int(2, 1) + _int(3, 3) + _msg(4, _int(1, 2))
_ALPHA = _int(1, 5) + _str(2, "S") + _msg(3, _TEST_EQ) + _msg(3, _TEST_CMP)


def _set(node, path, value) -> dict:
    return {"set_field": {"node": node, "path": path, "value": value}}


# @spec [RCTS.1.2.21]
class TestSetField:
    """`set_field`: one field of one RETE node atom, found by its
    `node_id`, set, removed or emptied, the messages on the way re-framed and
    the artefact re-sealed. The edits [RDSC.4a.3], [RDSC.4a.6],
    [RDSC.4a.6.1] and [RDSC.4a.9.1] need."""

    def _art(self) -> bytes:
        return seal(_HEADER + _atom(268, _ALPHA) + _term("r", _call(_LIT_INT)))

    def test_a_node_id_of_zero_is_written_after_the_other_fields(self) -> None:
        # Fails on: the terminal (node 3) edited, the id left in place beside
        # the new one, or a stale frame.
        out = _tampered(self._art(), _set(5, [1], 0))
        want = _str(2, "S") + _msg(3, _TEST_EQ) + _msg(3, _TEST_CMP) + _int(1, 0)
        assert out == seal(_HEADER + _atom(268, want) + _term("r", _call(_LIT_INT)))

    def test_an_empty_string_names_no_schema(self) -> None:
        out = _tampered(self._art(), _set(5, [2], ""))
        want = _int(1, 5) + _msg(3, _TEST_EQ) + _msg(3, _TEST_CMP) + _str(2, "")
        assert out == seal(_HEADER + _atom(268, want) + _term("r", _call(_LIT_INT)))

    def test_the_path_selects_one_occurrence_and_reframes_it(self) -> None:
        # Fails on: the first AlphaTest edited, both, or the second's frame
        # left stale (70000 is three varint bytes, 1 one).
        out = _tampered(self._art(), _set(5, [3, 1, 2], 70000))
        test = _int(1, 1) + _int(3, 3) + _msg(4, _int(1, 2)) + _int(2, 70000)
        want = _int(1, 5) + _str(2, "S") + _msg(3, _TEST_EQ) + _msg(3, test)
        assert out == seal(_HEADER + _atom(268, want) + _term("r", _call(_LIT_INT)))

    def test_null_removes_a_field_and_an_empty_string_empties_a_message(self) -> None:
        art = self._art()
        dropped = _tampered(art, _set(5, [3, 0, 4], None))
        assert dropped == seal(_HEADER + _atom(268, _int(1, 5) + _str(2, "S")
            + _msg(3, _int(2, 0)) + _msg(3, _TEST_CMP))
            + _term("r", _call(_LIT_INT)))
        emptied = _tampered(art, _set(5, [3, 0, 4], ""))
        assert emptied == seal(_HEADER + _atom(268, _int(1, 5) + _str(2, "S")
            + _msg(3, _int(2, 0) + _msg(4, b"")) + _msg(3, _TEST_CMP))
            + _term("r", _call(_LIT_INT)))

    def test_a_terminal_is_found_by_its_node_id_too(self) -> None:
        # _term's node_id is 3; its first action's expr (field 6, 0, 2) goes.
        out = _tampered(self._art(), _set(3, [6, 0, 2], None))
        assert out == seal(_HEADER + _atom(268, _ALPHA) + _term("r", b""))

    def test_without_a_site(self) -> None:
        # Fails on: a pass that edits nothing and reports success, which a
        # vector would read as the runtime refusing an unedited artefact.
        art = self._art()
        for tamper in (_set(99, [1], 0),           # no node 99
                       _set(5, [3, 2, 2], 0),      # no third AlphaTest
                       _set(5, [1, 0, 1], 0),      # node_id is no message
                       _set(5, [5], None)):        # no field 5 to remove
            assert _tampered(art, tamper) is None, tamper
        twice = seal(_HEADER + _atom(268, _ALPHA) + _atom(268, _ALPHA))
        assert _tampered(twice, _set(5, [1], 0)) is None   # two nodes 5

    def test_an_argument_of_another_shape_is_refused(self) -> None:
        art = self._art()
        for arg in ({"node": 0, "path": [1], "value": 0},
                    {"node": True, "path": [1], "value": 0},
                    {"node": 5, "path": [], "value": 0},
                    {"node": 5, "path": [3, 0], "value": 0},
                    {"node": 5, "path": [0], "value": 0},
                    {"node": 5, "path": [3, -1, 2], "value": 0},
                    {"node": 5, "path": "1", "value": 0},
                    {"node": 5, "path": [1], "value": -1},
                    {"node": 5, "path": [1], "value": True},
                    {"node": 5, "path": [1], "value": [0]},
                    {"node": 5, "path": [1]},
                    {"node": 5, "path": [1], "value": 0, "x": 1}):
            assert _tampered(art, {"set_field": arg}) is None, arg

    def test_an_atom_is_found_by_its_number_and_occurrence(self) -> None:
        # Fails on: the first occurrence edited for the second, or `atom`
        # read as a node id.
        art = seal(_HEADER + _atom(257, _SLOT_M) + _atom(257, _SLOT_N))
        out = _tampered(art, {"set_field": {"atom": [257, 1], "path": [2],
                                            "value": "k"}})
        want = b"\x0a\x01S" + b"\x18\x01" + b"\x58\x01" + _str(2, "k")
        assert out == seal(_HEADER + _atom(257, _SLOT_M) + _atom(257, want))
        for atom in ([257, 2], [258, 0], [0, 0], [257, -1], [257], [257, True]):
            arg = {"atom": atom, "path": [2], "value": "k"}
            assert _tampered(art, {"set_field": arg}) is None, atom
        both = {"atom": [257, 0], "node": 5, "path": [2], "value": "k"}
        assert _tampered(art, {"set_field": both}) is None

    def test_an_f64_is_written_as_a_double(self) -> None:
        # Fails on: the bits written most significant octet first, as a
        # varint, or with another wire type: a loader would then read some
        # value other than the NaN the fixture means ([RDSC.9.10]).
        art = seal(_HEADER + _atom(257, _SLOT_N))
        nan = {"f64": "7ff0000000000001"}
        out = _tampered(art, {"set_field": {"atom": [257, 0], "path": [7],
                                            "value": nan}})
        want = _SLOT_N + b"\x39" + bytes.fromhex("010000000000f07f")
        assert out == seal(_HEADER + _atom(257, want))
        for value in ({"f64": "7FF0000000000001"}, {"f64": "7ff00000000001"},
                      {"f64": 1}, {"f64": "7ff0000000000001", "x": 1},
                      {"g64": "7ff0000000000001"}):
            arg = {"atom": [257, 0], "path": [7], "value": value}
            assert _tampered(art, {"set_field": arg}) is None, value


_HEADER = _atom(263, b"\x3a\x20" + bytes(32))
# Slot S.n: schema_name 1, slot_name 2, kind 3 (INT), nullable 11.
_SLOT_N = b"\x0a\x01S" + b"\x12\x01n" + b"\x18\x01" + b"\x58\x01"
_SLOT_M = b"\x0a\x01S" + b"\x12\x01m" + b"\x18\x01"


class TestAddSlotSchemaRef:
    """`introspection_assert`'s `add_schema_ref` ([RDSC.5.5.5])."""

    def test_field_4_goes_in_ascending_order_and_the_artefact_is_resealed(self) -> None:
        # Fails on: field 4 appended after field 11, a frame length left
        # stale, an edit to the other Slot, or a missing re-seal.
        art = seal(_HEADER + _atom(257, _SLOT_M) + _atom(257, _SLOT_N))
        out = add_slot_schema_ref(art, "S", "n", "S")
        want_body = _SLOT_N[:8] + b"\x22\x01S" + _SLOT_N[8:]
        assert out == seal(_HEADER + _atom(257, _SLOT_M) + _atom(257, want_body))
        assert out != art and seal(out) == out

    def test_a_slot_that_is_not_there_has_no_site(self) -> None:
        art = seal(_HEADER + _atom(257, _SLOT_M))
        assert add_slot_schema_ref(art, "S", "n", "S") is None
        assert add_slot_schema_ref(art, "T", "m", "S") is None

    def test_two_slots_of_one_name_or_one_already_referring_have_no_site(self) -> None:
        twice = seal(_HEADER + _atom(257, _SLOT_N) + _atom(257, _SLOT_N))
        assert add_slot_schema_ref(twice, "S", "n", "S") is None
        has_ref = _SLOT_N[:8] + b"\x22\x01S" + _SLOT_N[8:]
        assert add_slot_schema_ref(seal(_HEADER + _atom(257, has_ref)),
                                   "S", "n", "S") is None


def _code_body(arch: bytes, node: int) -> bytes:
    """A `CompiledCode` body as [RCTS.1.2.31] states it, written out by hand:
    arch (1), node_id (2), kind CODE_KIND_RHS (3) and 64 zero octets of body
    (4), in ascending field order."""
    return (b"\x0a" + bytes([len(arch)]) + arch + b"\x10" + bytes([node])
            + b"\x18\x03" + b"\x22\x40" + bytes(64))


class TestAddCompiledCode:
    """`runtime_fact_count`'s `add_compiled_code` ([RCTS.1.2.31], [RDSC.4c.3])."""

    _TERM_3 = _atom(270, b"\x08\x03" + b"\x1a\x01r")    # node_id 3, rule "r"
    _TERM_4 = _atom(270, b"\x08\x04" + b"\x1a\x01q")

    def test_one_atom_per_well_known_arch_goes_after_the_last_atom(self) -> None:
        # Fails on: an atom inserted anywhere but the end, an arch left out or
        # out of order, a field out of ascending order, the wrong node or
        # kind, or a missing re-seal.
        art = seal(_HEADER + self._TERM_3 + self._TERM_4)
        out = add_compiled_code(art, 3)
        tail = b"".join(_atom(298, _code_body(a, 3))
                        for a in (b"amd64", b"arm64", b"rv64g", b"rv64gc"))
        assert out == seal(_HEADER + self._TERM_3 + self._TERM_4 + tail)
        assert out != art and seal(out) == out

    def test_a_node_no_terminal_carries_or_two_carry_has_no_site(self) -> None:
        art = seal(_HEADER + self._TERM_3)
        assert add_compiled_code(art, 4) is None
        twice = seal(_HEADER + self._TERM_3 + self._TERM_3)
        assert add_compiled_code(twice, 3) is None
        # An AlphaNode (268) with the id is no terminal.
        alpha = seal(_HEADER + _atom(268, b"\x08\x03"))
        assert add_compiled_code(alpha, 3) is None

    def test_an_artefact_whose_frames_do_not_walk_to_its_end_has_no_site(self) -> None:
        art = seal(_HEADER + self._TERM_3)
        assert add_compiled_code(art + b"\x0a", 3) is None


# A recording of three atoms: a FactAssert (1) of fact 1 for `Trig`, a
# PumpBoundary (4), and a FactRetract (2) of fact 1.
_FACT_ASSERT = _atom(1, b"\x08\x01" + b"\x12\x04Trig")
_RETRACT_BODY = b"\x08\x01\x10\x02"
_STREAM = _FACT_ASSERT + _atom(4, b"\x08\x01") + _atom(2, _RETRACT_BODY)


class TestStreamEdit:
    """`replay_refused`'s alterations ([RCTS.1.2.18])."""

    def test_rename_schema_replaces_every_occurrence_in_place(self) -> None:
        stream = _STREAM + _atom(256, b"\x0a\x04Trig")
        out = mutate(stream,
                     {"op": "rename_schema", "from": "Trig", "to": "Trih"})
        assert out is not None and b"Trig" not in out
        assert out.count(b"Trih") == 2 and len(out) == len(stream)

    def test_rename_schema_needs_two_names_of_one_length_and_a_site(self) -> None:
        # Fails on: a rename that moves a length, which breaks the frame.
        for frm, to in (("Trig", "Trigs"), ("Trig", "Trig"), ("", ""),
                        ("Gone", "Gona")):
            assert mutate(_STREAM, {"op": "rename_schema", "from": frm,
                                    "to": to}) is None

    def test_retract_unknown_fact_id_edits_the_retract_alone(self) -> None:
        out = mutate(_STREAM, {"op": "retract_unknown_fact_id"})
        retract_id = len(_STREAM) - len(_RETRACT_BODY) + 1
        assert out is not None and len(out) == len(_STREAM)
        assert [i for i, (a, b) in enumerate(zip(_STREAM, out)) if a != b] \
            == [retract_id]
        assert out[retract_id] == UNCARRIED_ID

    def test_retract_unknown_fact_id_needs_a_one_byte_id_nothing_carries(self) -> None:
        # Fails on: an id the recording does carry, which the reader accepts.
        no_retract = _FACT_ASSERT + _atom(4, b"\x08\x01")
        carried = _STREAM + _atom(1, b"\x08\x7f" + b"\x12\x04Trig")
        wide = _FACT_ASSERT + _atom(2, b"\x08\x80\x01")
        external = _STREAM + _atom(5, b"\x08\x03")
        for stream in (no_retract, carried, wide, external):
            assert mutate(stream, {"op": "retract_unknown_fact_id"}) is None

    def test_drop_schema_def_removes_the_announcement_whole(self) -> None:
        # Fails on: a Slot of the schema left behind, another schema's atoms
        # removed, the FactAssert dropped, or a byte of the rest moved.
        trig_def = _atom(256, b"\x0a\x04Trig")
        trig_slot = _atom(257, b"\x0a\x04Trig" + b"\x12\x01v")
        tick_def = _atom(256, b"\x0a\x04Tick")
        tick_slot = _atom(257, b"\x0a\x04Tick" + b"\x12\x01v")
        head = _atom(258, b"\x08\x01")
        stream = head + trig_def + trig_slot + tick_def + tick_slot + _STREAM
        out = mutate(stream, {"op": "drop_schema_def", "schema": "Trig"})
        assert out == head + tick_def + tick_slot + _STREAM

    def test_drop_schema_def_needs_an_announcement_and_an_assert(self) -> None:
        # Fails on: a recording that never asserted the schema, where the
        # replay has nothing to refuse, and a stream whose frames do not walk.
        announced = _atom(256, b"\x0a\x04Trig") + _STREAM
        unasserted = _atom(256, b"\x0a\x04Trig") + _atom(4, b"\x08\x01")
        for stream, schema in ((_STREAM, "Trig"), (announced, "Tick"),
                               (unasserted, "Trig"), (announced, ""),
                               (announced + b"\x0a", "Trig")):
            assert mutate(stream, {"op": "drop_schema_def",
                                   "schema": schema}) is None, schema
        for mutation in ({"op": "drop_schema_def"},
                         {"op": "drop_schema_def", "schema": 1},
                         {"op": "drop_schema_def", "schema": "Trig",
                          "slot": "v"}):
            assert mutate(announced, mutation) is None

    def test_a_mutation_outside_the_closed_set_has_no_site(self) -> None:
        for mutation in ({"op": "repeat_schema_def"}, {"op": "drop_atom"},
                         {"op": "retract_unknown_fact_id", "id": 9},
                         {"op": "unknown_capability", "value": 9},
                         {"op": "rename_schema", "from": "Trig"}, None, "x"):
            assert mutate(_STREAM, mutation) is None

    def test_unknown_capability_edits_the_header_list_alone(self) -> None:
        # Fails on: an entry other than the first edited, a number Capability
        # allocates written, or a length moved.
        header = _atom(258, _str(10, "0.19") + _msg(16, bytes([4, 6])))
        stream = header + _STREAM
        out = mutate(stream, {"op": "unknown_capability"})
        first = len(header) - 2
        assert out is not None and len(out) == len(stream)
        assert _diff(stream, out) == [first]
        assert out[first] == UNALLOCATED_CAPABILITY

    def test_unknown_capability_needs_a_packed_list_of_one_byte_entries(self) -> None:
        none = _atom(258, _str(10, "0.19"))
        unpacked = _atom(258, _int(16, 4) + _int(16, 6))
        wide = _atom(258, _msg(16, b"\xc8\x01\x04"))
        for stream in (_STREAM, none + _STREAM, unpacked + _STREAM,
                       wide + _STREAM):
            assert mutate(stream, {"op": "unknown_capability"}) is None

    def test_withdraw_cause_edits_the_index_th_withdrawal_alone(self) -> None:
        # Fails on: the wrong FactWithdraw edited (the first, whatever the
        # index), another field of it, or a length moved.
        first = _atom(327, _int(1, 1) + _int(2, 2))
        second = _atom(327, _int(1, 2) + _int(2, 2))
        stream = _STREAM + first + second
        out = mutate(stream, {"op": "withdraw_cause", "index": 1, "cause": 4})
        cause_at = len(stream) - 1
        assert out is not None and len(out) == len(stream)
        assert _diff(stream, out) == [cause_at]
        assert out[cause_at] == 4

    def test_withdraw_cause_without_a_site(self) -> None:
        # Fails on: an index past the withdrawals, a cause proto3 did
        # not write, a cause wider than one byte, the cause it already is,
        # and an index or cause out of range or of the wrong type -- each of
        # which a harness must fail rather than replay unaltered.
        one = _STREAM + _atom(327, _int(1, 1) + _int(2, 2))
        unwritten = _STREAM + _atom(327, _int(1, 1))
        wide = _STREAM + _atom(327, _int(1, 1) + b"\x10\x80\x01")
        for stream, mutation in (
                (_STREAM, {"index": 0, "cause": 4}),
                (one, {"index": 1, "cause": 4}),
                (unwritten, {"index": 0, "cause": 4}),
                (wide, {"index": 0, "cause": 4}),
                (one, {"index": 0, "cause": 2}),
                (one, {"index": -1, "cause": 4}),
                (one, {"index": True, "cause": 4}),
                (one, {"index": "0", "cause": 4}),
                (one, {"index": 0, "cause": 0}),
                (one, {"index": 0, "cause": 128}),
                (one, {"index": 0, "cause": True}),
                (one, {"index": 0, "cause": 4.0}),
                (one, {"index": 0}),
                (one, {"index": 0, "cause": 4, "extra": 1})):
            assert mutate(stream, {"op": "withdraw_cause", **mutation}) is None, \
                mutation

    @staticmethod
    def _publish(schema: str, rule: str, clock: int) -> bytes:
        return _atom(331, _str(1, schema) + _str(2, rule) + _int(3, clock))

    def test_publish_name_edits_the_index_th_publish_s_name_alone(self) -> None:
        # Fails on: the first FactPublish edited whatever the index, the other
        # name or another field edited, or a length moved.
        first, second = self._publish("Pub", "r", 5), self._publish("Pub", "r", 6)
        stream = _STREAM + first + second
        out = mutate(stream, {"op": "publish_name", "index": 1,
                              "field": "schema_name", "to": "Puc"})
        assert out == _STREAM + first + self._publish("Puc", "r", 6)
        out = mutate(stream, {"op": "publish_name", "index": 0,
                              "field": "rule_name", "to": "s"})
        assert out == _STREAM + self._publish("Pub", "s", 5) + second
        # UTF-8 octets, not code points: two octets for two.
        out = mutate(_STREAM + self._publish("Pub", "ré", 5),
                     {"op": "publish_name", "index": 0,
                      "field": "rule_name", "to": "rf"})
        assert out is None
        out = mutate(_STREAM + self._publish("Pub", "ab", 5),
                     {"op": "publish_name", "index": 0,
                      "field": "rule_name", "to": "é"})
        assert out == _STREAM + self._publish("Pub", "é", 5)

    def test_publish_name_without_a_site(self) -> None:
        # Fails on: no index-th FactPublish, a name proto3 did not write, a
        # `to` of another length or equal to what it replaces, a field that
        # is neither name, and members out of range, of the wrong type, missing
        # or extra -- each of which a harness must fail rather than replay
        # unaltered.
        one = _STREAM + self._publish("Pub", "r", 5)
        unwritten = _STREAM + _atom(331, _str(1, "Pub"))
        for stream, mutation in (
                (_STREAM, {"index": 0, "field": "schema_name", "to": "Puc"}),
                (one, {"index": 1, "field": "schema_name", "to": "Puc"}),
                (unwritten, {"index": 0, "field": "rule_name", "to": "s"}),
                (one, {"index": 0, "field": "schema_name", "to": "Pu"}),
                (one, {"index": 0, "field": "schema_name", "to": "Pubs"}),
                (one, {"index": 0, "field": "schema_name", "to": "Pub"}),
                (one, {"index": 0, "field": "clock_ns", "to": "Puc"}),
                (one, {"index": -1, "field": "schema_name", "to": "Puc"}),
                (one, {"index": True, "field": "schema_name", "to": "Puc"}),
                (one, {"index": 0, "field": 1, "to": "Puc"}),
                (one, {"index": 0, "field": "schema_name", "to": 5}),
                (one, {"index": 0, "field": "schema_name"}),
                (one, {"index": 0, "field": "schema_name", "to": "Puc",
                       "extra": 1})):
            assert mutate(stream, {"op": "publish_name", **mutation}) is None, \
                mutation

    def test_fault_node_raises_the_first_fault_s_node_id_alone(self) -> None:
        # Fails on: another atom edited, the second of the kind, another
        # field, or a length moved.
        first = _atom(328, _int(1, 5) + _int(6, 9))
        stream = _STREAM + first + _atom(328, _int(1, 6))
        out = mutate(stream, {"op": "fault_node", "atom": "TypeError"})
        at = len(_STREAM) + len(first) - 3
        assert out is not None and _diff(stream, out) == [at]
        assert out[at] == 6

    def test_fault_node_without_a_site(self) -> None:
        unwritten = _STREAM + _atom(325, _int(6, 1))
        top = _STREAM + _atom(328, _int(1, 127))
        wide = _STREAM + _atom(328, b"\x08\x80\x01")
        for stream, atom in ((_STREAM, "TypeError"), (unwritten, "ComputationError"),
                             (top, "TypeError"), (wide, "TypeError"),
                             (top, "EngineError"), (top, 328)):
            assert mutate(stream, {"op": "fault_node", "atom": atom}) is None, atom

    def test_drop_fault_removes_the_first_fault_s_frame_alone(self) -> None:
        # Fails on: the second removed, another atom removed, or a byte
        # of the rest changed.
        first, second = _atom(325, _int(7, 1)), _atom(325, _int(7, 2))
        out = mutate(_STREAM + first + second,
                     {"op": "drop_fault", "atom": "ComputationError"})
        assert out == _STREAM + second

    def test_drop_fault_without_a_site(self) -> None:
        one = _STREAM + _atom(325, _int(7, 1))
        for stream, atom in ((_STREAM, "ComputationError"), (one, "TypeError"),
                             (one + b"\xff", "ComputationError"),
                             (one, "EngineError")):
            assert mutate(stream, {"op": "drop_fault", "atom": atom}) is None, atom

    def test_append_engine_error_adds_one_frame_after_the_rest(self) -> None:
        # Fails on: a byte of the rest changed, or another field written.
        out = mutate(_STREAM, {"op": "append_engine_error"})
        want = _atom(330, _int(1, 1) + _int(4, 999) + _str(5, "r"))
        assert out == _STREAM + want

    def test_append_engine_error_without_a_site(self) -> None:
        held = _STREAM + _atom(330, _int(1, 1))
        for stream in (held, _STREAM + b"\xff", b""):
            assert mutate(stream, {"op": "append_engine_error"}) is None

    def test_seed_after_event_moves_the_first_seed_past_the_first_event(self) -> None:
        # Fails on: the seed moved past a SchemaDef, a Slot or another
        # CacheSeed, which is still the prelude; the second seed moved instead
        # of the first; or a frame's bytes changed rather than its place.
        header, sdef, slot = (_atom(258, _str(10, "0.19")),
                              _atom(256, _str(1, "Trig")),
                              _atom(257, _str(1, "Trig")))
        seed_a, seed_b = _atom(6, _str(1, "a")), _atom(6, _str(1, "b"))
        clock, fact = _atom(3, _int(1, 5)), _atom(1, _int(1, 1))
        stream = header + sdef + slot + seed_a + seed_b + clock + fact
        out = mutate(stream, {"op": "seed_after_event"})
        assert out == header + sdef + slot + seed_b + clock + seed_a + fact

    def test_seed_after_event_without_a_site(self) -> None:
        # Fails on: a recording with no seed, or with no event after it, that
        # a harness would replay unaltered; or a member it does not take.
        header, seed = _atom(258, _str(10, "0.19")), _atom(6, _str(1, "a"))
        clock = _atom(3, _int(1, 5))
        for stream, mutation in ((header + clock, {"op": "seed_after_event"}),
                                 (header + seed, {"op": "seed_after_event"}),
                                 (header + seed + clock,
                                  {"op": "seed_after_event", "index": 0})):
            assert mutate(stream, mutation) is None


def _caps_header(caps: bytes) -> bytes:
    """A DscHeader (263): its `dsc_sha256` (field 7), then `capabilities`
    (field 13) packed as `caps`."""
    return _atom(263, b"\x3a\x20" + bytes(32) + _msg(13, caps))


# @spec [RCTS.1.2.21]
class TestCapabilityTampers:
    """[RBND.1.3]'s malformed `capabilities` list: two tamper members
    that edit the header's list in place and re-seal ([RCTS.1.2.21])."""

    def test_duplicate_capability_copies_the_entry_forward_and_reseals(self) -> None:
        # Fails on: the wrong entry copied, the list re-sorted or cut, or
        # the hash left as it was.
        art = seal(_caps_header(bytes([4, 6, 8])) + _atom(257, _SLOT_BODY))
        out = _tampered(art, {"duplicate_capability": 1})
        assert out == seal(_caps_header(bytes([4, 6, 6]))
                           + _atom(257, _SLOT_BODY))

    def test_swap_capabilities_swaps_the_pair_and_reseals(self) -> None:
        art = seal(_caps_header(bytes([4, 6, 8])))
        out = _tampered(art, {"swap_capabilities": 0})
        assert out == seal(_caps_header(bytes([6, 4, 8])))
        assert len(out) == len(art)

    def test_the_two_members_without_a_site(self) -> None:
        # Fails on: an index past the list, a list that would need a length
        # moved, or a list written unpacked accepted as if it were packed.
        art = seal(_caps_header(bytes([4, 6])))
        one = seal(_caps_header(bytes([4])))
        wide = seal(_caps_header(b"\x04\xc8\x01"))
        unpacked = seal(_atom(263, b"\x3a\x20" + bytes(32)
                              + _int(13, 4) + _int(13, 6)))
        for op in ("duplicate_capability", "swap_capabilities"):
            assert _tampered(art, {op: 1}) is None
            assert _tampered(art, {op: -1}) is None
            assert _tampered(art, {op: True}) is None
            assert _tampered(art, {op: "0"}) is None
            assert _tampered(one, {op: 0}) is None
            assert _tampered(wide, {op: 0}) is None
            assert _tampered(unpacked, {op: 0}) is None
            assert _tampered(seal(_HEADER), {op: 0}) is None


_THREE_STEPS = [{"op": "pump"}, {"op": "pump"}, {"op": "pump"}]


# @spec [RCTS.1.2.18]
class TestLateStart:
    """`replay_refused`'s `late_start` ([RCTS.1.2.18], [LTIM.2.8.5])."""

    def test_a_count_inside_the_steps_is_taken(self) -> None:
        assert _late_start({"steps": _THREE_STEPS, "late_start": 1}) == 1
        assert _late_start({"steps": _THREE_STEPS, "late_start": 2}) == 2

    def test_a_mutation_alone_has_no_late_start(self) -> None:
        assert _late_start({"steps": _THREE_STEPS,
                            "mutation": {"op": "retract_unknown_fact_id"}}) is None

    def test_both_fields_or_neither_is_malformed(self) -> None:
        # Fails on: a harness that prefers one field and drops the other, so
        # the fixture's author never learns which alteration ran.
        both = {"steps": _THREE_STEPS, "late_start": 1,
                "mutation": {"op": "retract_unknown_fact_id"}}
        assert isinstance(_late_start(both), str)
        assert isinstance(_late_start({"steps": _THREE_STEPS}), str)

    def test_a_count_that_records_all_or_nothing_is_malformed(self) -> None:
        # Fails on: 0, which records the whole session and so is no
        # alteration, and the step count, which records nothing at all.
        for n in (0, 3, 4, -1, True, 1.0, "1", None):
            assert isinstance(
                _late_start({"steps": _THREE_STEPS, "late_start": n}), str), n

    def test_a_replay_cache_cap_alone_is_the_alteration(self) -> None:
        # Fails on: a cap beside another alteration, so the refusal
        # could be either's; or one of another shape, which bounds nothing.
        mutation = {"op": "retract_unknown_fact_id"}
        for cap in ({"keys": 1}, {"bytes": 8}, {"keys": 1, "bytes": 8}, {}):
            assert _late_start({"steps": _THREE_STEPS,
                                "replay_cache_cap": cap}) is None, cap
        for extra in ({"mutation": mutation}, {"late_start": 1}):
            assert isinstance(_late_start({"steps": _THREE_STEPS,
                                           "replay_cache_cap": {"keys": 1},
                                           **extra}), str), extra
        for cap in ({"keys": -1}, {"keys": True}, {"entries": 1}, [1], 1):
            assert isinstance(_late_start({"steps": _THREE_STEPS,
                                           "replay_cache_cap": cap}), str), cap

    def test_replay_cache_cap_is_replay_refused_s_alone(self) -> None:
        for kind in ("replay_determinism", "rfcs_roundtrip", "runtime_error"):
            why = _replay_cache_cap_misplaced(
                _Fixture({"kind": kind, "replay_cache_cap": {"keys": 1}}))
            assert why is not None and "RCTS.1.2.18" in why, kind
        assert _replay_cache_cap_misplaced(_Fixture(
            {"kind": "replay_refused", "replay_cache_cap": {"keys": 1}})) is None


def _note(tt: int) -> bytes:
    """A RuleFireAnnotation (261): a rule name (field 2) and `timetag` (6)."""
    return _atom(261, _str(2, "r") + _int(6, tt))


class _Fixture:
    def __init__(self, expect: dict) -> None:
        self.expect = expect


# @spec [RCTS.1.2.24]
class TestTimetagOffset:
    """`replay_determinism`'s `timetag_offset` ([RCTS.1.2.24])."""

    def test_every_nonzero_timetag_is_offset_and_each_changed_atom_reframed(self) -> None:
        # Fails on: an atom kind left out, a zero timetag offset (zero is no
        # timetag), another field touched, or a frame whose length was not
        # rewritten when the varint widened (100 + 200 needs two bytes).
        call = _atom(262, _str(1, "svc") + _int(8, 100))
        fault = _atom(325, _str(1, "r") + _int(3, 0))
        bounds = _atom(329, _int(5, 100))
        stream = _FACT_ASSERT + _note(100) + call + fault + bounds
        out = offset_timetags(stream, 200)
        assert out == (_FACT_ASSERT + _note(300)
                       + _atom(262, _str(1, "svc") + _int(8, 300))
                       + fault + _atom(329, _int(5, 300)))

    def test_a_recording_with_no_nonzero_timetag_has_nothing_to_offset(self) -> None:
        assert offset_timetags(_STREAM, 5) is None
        assert offset_timetags(_STREAM + _atom(325, _int(3, 0)), 5) is None

    def test_n_must_be_a_positive_integer(self) -> None:
        assert _timetag_offset({"timetag_offset": 1}) == 1
        assert _timetag_offset({}) is None
        for n in (0, -1, True, 1.0, "1", None):
            assert isinstance(_timetag_offset({"timetag_offset": n}), str), n

    def test_the_field_is_replay_determinisms_alone(self) -> None:
        # Fails on: a kind that would carry the field and never read it.
        assert _timetag_offset_misplaced(_Fixture(
            {"kind": "replay_determinism", "timetag_offset": 1})) is None
        for kind in ("replay_refused", "rfcs_roundtrip", "event_sequence"):
            assert isinstance(_timetag_offset_misplaced(_Fixture(
                {"kind": kind, "timetag_offset": 1})), str), kind


# @spec [RCTS.1.2.18]
class TestMergeTimetags:
    """`replay_refused`'s `merge_timetags` ([RCTS.1.2.18], [LFST.9.3.6])."""

    def test_the_j_th_timetag_becomes_the_i_th_wherever_it_is_carried(self) -> None:
        # Fails on: an atom carrying the j-th value left alone, the i-th's
        # own atom edited, or a length moved.
        stream = (_note(5) + _note(7) + _atom(262, _int(8, 7))
                  + _atom(329, _int(5, 7)) + _atom(262, _int(8, 9)))
        out = mutate(stream, {"op": "merge_timetags", "firings": [0, 1]})
        assert out == (_note(5) + _note(5) + _atom(262, _int(8, 5))
                       + _atom(329, _int(5, 5)) + _atom(262, _int(8, 9)))
        assert len(out) == len(stream)

    def test_merge_timetags_without_a_site(self) -> None:
        # Fails on: an index with no annotation, two that already share a
        # timetag, two whose varints differ in width (5 and 200), and
        # firings of the wrong shape or type.
        two = _note(5) + _note(7)
        for stream, firings in (
                (two, [1, 0]), (two, [0, 0]), (two, [0, 2]), (two, [-1, 1]),
                (_note(5) + _note(5), [0, 1]),
                (_note(5) + _note(200), [0, 1]),
                (two, [0, True]), (two, ["0", 1]), (two, [0]),
                (two, [0, 1, 1]), (two, "0,1")):
            assert mutate(stream, {"op": "merge_timetags",
                                   "firings": firings}) is None, firings
        assert mutate(two, {"op": "merge_timetags", "firings": [0, 1],
                            "extra": 1}) is None
        assert mutate(two, {"op": "merge_timetags"}) is None


def _issued(tt: int) -> bytes:
    """A CallIssued (262): a service (field 1) and `timetag` (8). Not
    `_call`, which is a DSC call action above."""
    return _atom(262, _str(1, "svc") + _int(8, tt))


# @spec [RCTS.1.2.18]
class TestSplitTimetag:
    """`replay_refused`'s `split_timetag` ([RCTS.1.2.18], [LFST.9.3.6]'s
    second direction)."""

    def test_the_call_takes_the_least_free_value_of_its_width(self) -> None:
        # Fails on: a value another atom carries (1 and 2 are taken), the
        # firing's annotations edited, the wrong call edited, or a length
        # moved.
        stream = (_note(5) + _issued(5) + _issued(5) + _note(5)
                  + _note(1) + _atom(329, _int(5, 2)))
        out = mutate(stream, {"op": "split_timetag", "atom": 1})
        assert out == (_note(5) + _issued(5) + _issued(3) + _note(5)
                       + _note(1) + _atom(329, _int(5, 2)))

    def test_a_two_byte_timetag_takes_a_two_byte_value(self) -> None:
        # Fails on: a value that narrows the varint (1), which moves a length.
        stream = _note(200) + _issued(200) + _note(200)
        out = mutate(stream, {"op": "split_timetag", "atom": 0})
        assert out == _note(200) + _issued(128) + _note(200)
        assert len(out) == len(stream)

    def test_split_timetag_without_a_site(self) -> None:
        # Fails on: an index past the calls, a call whose timetag is not
        # written, a width with no free value, and an `atom` of the wrong
        # type, each of which a harness must fail rather than replay
        # unaltered.
        one = _note(5) + _issued(5) + _note(5)
        unwritten = _note(5) + _atom(262, _str(1, "svc")) + _note(5)
        full = b"".join(_note(v) for v in range(1, 128)) + _issued(5)
        for stream, atom in ((_note(5), 0), (one, 1), (unwritten, 0),
                             (full, 0), (one, -1), (one, True), (one, "0"),
                             (one, 0.0)):
            assert mutate(stream, {"op": "split_timetag", "atom": atom}) \
                is None, atom
        assert mutate(one, {"op": "split_timetag"}) is None
        assert mutate(one, {"op": "split_timetag", "atom": 0,
                            "extra": 1}) is None
