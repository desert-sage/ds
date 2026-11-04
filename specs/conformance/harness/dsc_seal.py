# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The artefact's own `dsc_sha256` ([RDSC.3.6]): where it is, and how to seal;
where an atom's body starts, for a test that edits one; the atoms
`runtime_error`'s structural tampers remove (`drop_schema_group`,
`drop_terminal_parent`) or edit (`drop_call_operand`, and [RDSC.11.3]'s four
shapes: `drop_action_expr`, `clear_action_expr`, `drop_assign_expr`,
`nest_action_expr`) or make malformed (the header's `capabilities`, for
[RBND.1.3]: `capabilities_edited`) or set (`set_field`); the whole frames
[RDSC.11.1]'s rows need removed or added (`drop_atom`, `insert_bytes`); the
`schema_ref` a fixture adds to a
Slot (`add_slot_schema_ref`); and the `CompiledCode` atoms a fixture appends
for a runtime to skip (`add_compiled_code`).

A runtime recomputes `dsc_sha256` at load with the field zeroed and refuses a
mismatch, so a test that edits a compiled artefact and
means to test something OTHER than the hash re-seals it first, as the compiler
does: zero the field, hash the whole artefact, write the digest in.

The field is found by WALKING the frames to the first DscHeader (field 263,
[RFCS.19.4]), the first atom of a compiled artefact, and the hash is field 7
of its body, 32 bytes. Walked rather than searched for, because a search for
32 bytes also finds them anywhere else they occur. An edit can remove the
header or put bytes before it (`drop_atom`, `insert_bytes`); where the walk
then reaches no header, there is nothing to seal ([RCTS.1.2.21]).

Not a test module: `runner.py` and the hypothesis properties that edit
artefacts import it.
"""
from __future__ import annotations

import hashlib


def _varint(buf: bytes, pos: int) -> tuple[int, int] | None:
    """A protobuf varint at `pos`: (value, next position), or None if it runs
    off the end."""
    val = shift = 0
    while pos < len(buf) and shift < 64:
        b = buf[pos]
        val |= (b & 0x7F) << shift
        pos += 1
        if not b & 0x80:
            return val, pos
        shift += 7
    return None


def sha256_offset(dsc: bytes) -> int | None:
    """Offset of the 32 `dsc_sha256` bytes: field 7 of the first DscHeader
    atom a walk of the frames reaches from the first byte ([RCTS.1.2.21]),
    which in a compiled artefact is its first atom. None when the walk reaches
    no DscHeader, or its body does not walk to that field: an edit that
    removed or displaced the header past what the walk reaches leaves no hash
    to seal."""
    header = next((f for f in atom_frames(dsc) if f[0] == _DSC_HEADER), None)
    if header is None:
        return None
    pos, end = header[3], header[4]
    while pos < end:
        step = _varint(dsc, pos)
        if step is None:
            return None
        key, pos = step
        field, wire = key >> 3, key & 7
        if wire == 2:
            step = _varint(dsc, pos)
            if step is None:
                return None
            length, pos = step
            if field == 7 and length == 32:
                return pos
            pos += length
        elif wire == 0:
            step = _varint(dsc, pos)
            if step is None:
                return None
            pos = step[1]
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            return None
    return None


def atom_body_offset(dsc: bytes, field: int) -> int | None:
    """Offset of the body of the first top-level atom whose field number is
    `field`, or None when there is none or the frames do not walk. Each atom
    is an outer field 1 (`0x0A`, length) holding one inner field (the atom's
    number, wire type 2, length, body) ([RFCS.19.1])."""
    pos = 0
    while pos < len(dsc):
        if dsc[pos] != 0x0A:
            return None
        step = _varint(dsc, pos + 1)
        if step is None:
            return None
        outer_len, inner = step
        end = inner + outer_len
        step = _varint(dsc, inner)
        if step is None:
            return None
        key, pos_len = step
        step = _varint(dsc, pos_len)
        if step is None:
            return None
        body_len, body = step
        if key == (field << 3) | 2 and body_len > 0 and body + body_len <= end:
            return body
        pos = end
    return None


# Atom numbers the structural tampers read (proto/atom.proto).
SCHEMA_DEF = 256
SCHEMA_LIFECYCLE = (299, 300)       # SchemaLogical, SchemaTtl ([RDSC.8.1])
BETA_NODE = 269
TERMINAL_NODE = 270


def atom_frames(dsc: bytes) -> list[tuple[int, int, int, int, int]]:
    """(atom number, frame start, frame end, body start, body end) of each
    top-level atom, in order, up to the first frame that does not walk."""
    out = []
    pos = 0
    while pos < len(dsc) and dsc[pos] == 0x0A:
        step = _varint(dsc, pos + 1)
        if step is None:
            break
        outer_len, inner = step
        end = inner + outer_len
        step = _varint(dsc, inner)
        if step is None or step[0] & 7 != 2:
            break
        key, at = step
        step = _varint(dsc, at)
        if step is None or step[1] + step[0] > end or end > len(dsc):
            break
        out.append((key >> 3, pos, end, step[1], step[1] + step[0]))
        pos = end
    return out


def drop_atom(dsc: bytes, index: int) -> bytes | None:
    """[RCTS.1.2.21]'s `drop_atom`: `dsc` without the frame of its atom
    `index`, counted from 0 by `atom_frames`, so 0 removes the DscHeader.
    None when the walk reaches no such atom. Not re-sealed. `test_behave.m`
    makes the same edit with its own walk (`atom_dropped`)."""
    frames = atom_frames(dsc)
    if not 0 <= index < len(frames):
        return None
    _, start, end, _, _ = frames[index]
    return dsc[:start] + dsc[end:]


def insert_bytes(dsc: bytes, index: int, octets: bytes) -> bytes | None:
    """[RCTS.1.2.21]'s `insert_bytes`: `dsc` with `octets` inserted before its
    atom `index`, counted from 0 by `atom_frames`, or after its last atom when
    `index` is their number. The octets need not be a frame: they make the
    malformed frames, short frames and padding [RDSC.11.1] refuses. None when
    `index` is past that number, or the walk stops before `dsc`'s end. Not
    re-sealed. `test_behave.m` makes the same edit with its own walk
    (`bytes_inserted`)."""
    frames = atom_frames(dsc)
    if (frames[-1][2] if frames else 0) != len(dsc):
        return None
    if not 0 <= index <= len(frames):
        return None
    at = frames[index][1] if index < len(frames) else len(dsc)
    return dsc[:at] + octets + dsc[at:]


def _field(buf: bytes, start: int, end: int, field: int, wire: int):
    """The value of the first field `field` with wire type `wire` in the body
    `buf[start:end]`: the bytes for wire type 2, the integer for 0; an absent
    varint field is 0, as proto3 reads it, and an absent bytes field None."""
    pos = start
    while pos < end:
        step = _varint(buf, pos)
        if step is None:
            return None
        key, pos = step
        num, w = key >> 3, key & 7
        if w == 0:
            step = _varint(buf, pos)
            if step is None:
                return None
            if num == field and wire == 0:
                return step[0]
            pos = step[1]
        elif w == 2:
            step = _varint(buf, pos)
            if step is None:
                return None
            length, pos = step
            if num == field and wire == 2:
                return buf[pos:pos + length]
            pos += length
        elif w == 1:
            pos += 8
        elif w == 5:
            pos += 4
        else:
            return None
    return 0 if wire == 0 else None


def drop_schema_group(dsc: bytes, schema: str) -> bytes | None:
    """`dsc` without `schema`'s schema group: its atoms from the lifecycle atom
    through its `SchemaDef` ([RDSC.8.1]), so nothing in the artefact
    declares the schema. None when no `SchemaDef` names it or none of the
    lifecycle atoms precedes it. Not re-sealed."""
    frames = atom_frames(dsc)
    name = schema.encode("utf-8")
    for i, (num, _, frame_end, start, end) in enumerate(frames):
        if num == SCHEMA_DEF and _field(dsc, start, end, 1, 2) == name:
            life = [f for f in frames[:i] if f[0] in SCHEMA_LIFECYCLE]
            if not life:
                return None
            return dsc[:life[-1][1]] + dsc[frame_end:]
    return None


def drop_terminal_parent(dsc: bytes, rule: str) -> bytes | None:
    """`dsc` without the `BetaNode` that `rule`'s `TerminalNode` names as its
    `parent_beta_id`, so that id names no node ([RDSC.11.1]). None when no
    terminal realizes `rule`, it names no parent, or no `BetaNode` carries
    that id. Not re-sealed."""
    frames = atom_frames(dsc)
    name = rule.encode("utf-8")
    term = next((f for f in frames if f[0] == TERMINAL_NODE
                 and _field(dsc, f[3], f[4], 3, 2) == name), None)
    if term is None:
        return None
    parent = _field(dsc, term[3], term[4], 2, 0)
    if not parent:
        return None
    beta = next((f for f in frames if f[0] == BETA_NODE
                 and _field(dsc, f[3], f[4], 1, 0) == parent), None)
    if beta is None:
        return None
    return dsc[:beta[1]] + dsc[beta[2]:]


_SLOT_ATOM = 257
_SCHEMA_REF_FIELD = 4


def _put_varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _fields(body: bytes) -> list[tuple[int, int, bytes]] | None:
    """Each field of a message body as (number, start, value), the value the
    bytes of a length-delimited field and b"" for any other; None when the body
    does not walk."""
    out: list[tuple[int, int, bytes]] = []
    pos = 0
    while pos < len(body):
        start = pos
        step = _varint(body, pos)
        if step is None:
            return None
        key, pos = step
        wire = key & 7
        value = b""
        if wire == 0:
            step = _varint(body, pos)
            if step is None:
                return None
            pos = step[1]
        elif wire == 1:
            pos += 8
        elif wire == 2:
            step = _varint(body, pos)
            if step is None:
                return None
            length, pos = step
            value = body[pos:pos + length]
            pos += length
        elif wire == 5:
            pos += 4
        else:
            return None
        if pos > len(body):
            return None
        out.append((key >> 3, start, value))
    return out


def add_slot_schema_ref(dsc: bytes, schema: str, slot: str,
                        ref: str) -> bytes | None:
    """`dsc` with its one Slot atom (257) for (`schema`, `slot`) given field 4,
    `schema_ref` = `ref`, at its place in ascending field order, re-framed and
    re-sealed ([RDSC.5.5.5]). No compiler writes a reference on a slot
    that is not a schema slot, so this is how a fixture hands a runtime one.
    None when there is not exactly one such Slot, when it already carries a
    `schema_ref`, or when the frames or its body do not walk. The Mercury
    runtime's pass, `test_behave.m`, makes the same edit with its own walk
    (`schema_ref_added`), so the two runtimes are not handed one reading."""
    hits = []
    pos = 0
    while pos < len(dsc):
        if dsc[pos] != 0x0A:
            return None
        step = _varint(dsc, pos + 1)
        if step is None:
            return None
        outer_len, inner = step
        end = inner + outer_len
        step = _varint(dsc, inner)
        if step is None:
            return None
        key, at = step
        step = _varint(dsc, at)
        if step is None:
            return None
        body_len, body = step
        if body + body_len != end or end > len(dsc):
            return None
        if key == (_SLOT_ATOM << 3) | 2:
            fields = _fields(dsc[body:end])
            if fields is None:
                return None
            named = {n: v for n, _, v in reversed(fields)}   # the first of each
            if (named.get(1) == schema.encode()
                    and named.get(2) == slot.encode()):
                hits.append((pos, body, end, fields))
        pos = end
    if len(hits) != 1:
        return None
    start, body, end, fields = hits[0]
    if any(n == _SCHEMA_REF_FIELD for n, _, _ in fields):
        return None
    old = dsc[body:end]
    cut = next((s for n, s, _ in fields if n > _SCHEMA_REF_FIELD), len(old))
    ref_b = ref.encode()
    new_body = (old[:cut] + _put_varint((_SCHEMA_REF_FIELD << 3) | 2)
                + _put_varint(len(ref_b)) + ref_b + old[cut:])
    inner_b = (_put_varint((_SLOT_ATOM << 3) | 2) + _put_varint(len(new_body))
               + new_body)
    atom = b"\x0a" + _put_varint(len(inner_b)) + inner_b
    return seal(dsc[:start] + atom + dsc[end:])


# proto/atom.proto's `compiled_code` and proto/aot.proto's `CompiledCode`, as
# `add_compiled_code` writes it ([RCTS.1.2.31]).
COMPILED_CODE = 298
_CODE_ARCHES = ("amd64", "arm64", "rv64g", "rv64gc")   # aot.proto's well-known
_CODE_KIND_RHS = 3
_CODE_BODY = bytes(64)


def compiled_code_atom(arch: str, node: int) -> bytes:
    """One framed `CompiledCode` atom: `arch`, `node_id` `node`, `kind`
    `CODE_KIND_RHS` and a `body` of 64 zero octets, its fields in ascending
    order ([RFCS.19.5])."""
    a = arch.encode()
    body = (_put_varint((1 << 3) | 2) + _put_varint(len(a)) + a
            + _put_varint(2 << 3) + _put_varint(node)
            + _put_varint(3 << 3) + _put_varint(_CODE_KIND_RHS)
            + _put_varint((4 << 3) | 2) + _put_varint(len(_CODE_BODY))
            + _CODE_BODY)
    inner = _put_varint((COMPILED_CODE << 3) | 2) + _put_varint(len(body)) + body
    return b"\x0a" + _put_varint(len(inner)) + inner


def add_compiled_code(dsc: bytes, node: int) -> bytes | None:
    """`dsc` with one `CompiledCode` atom for each of aot.proto's well-known
    `arch` values appended after its last atom, each an RHS for the
    `TerminalNode` whose `node_id` is `node`, and re-sealed
    ([RCTS.1.2.31]). No compiler of this edition writes the atom
    ([RDSC.4c.3]), so this is how a fixture gives a runtime one for the
    architecture it runs on. None when there is not exactly one such
    `TerminalNode`, or when the frames do not walk to the artefact's end. The
    Mercury runtime's pass, `test_behave.m`, makes the same edit with its own
    walk (`compiled_code_added`)."""
    frames = atom_frames(dsc)
    if not frames or frames[-1][2] != len(dsc):
        return None
    terms = [f for f in frames if f[0] == TERMINAL_NODE
             and _field(dsc, f[3], f[4], 1, 0) == node]
    if len(terms) != 1:
        return None
    return seal(dsc + b"".join(compiled_code_atom(a, node)
                               for a in _CODE_ARCHES))


# proto/term.proto and proto/rete_expr.proto, as `drop_call_operand` reads them.
_TERM_ACTIONS = 6          # TerminalNode.actions
_ACTION_KIND = 1           # Action.kind; ACTION_CALL = 0, proto3's absent value
_ACTION_EXPR = 2           # Action.expr
_EXPR_CALL = 8             # Expr.call
_CALL_ARGS = 2             # CallExpr.args


def _delimited(field: int, value: bytes) -> bytes:
    return _put_varint((field << 3) | 2) + _put_varint(len(value)) + value


def _spans(body: bytes) -> list[tuple[int, int, int, bytes]] | None:
    """Each field of `body` as (number, start, end, value), `end` where the
    next field starts; None when the body does not walk."""
    fields = _fields(body)
    if fields is None:
        return None
    ends = [s for _, s, _ in fields[1:]] + [len(body)]
    return [(n, s, e, v) for (n, s, v), e in zip(fields, ends)]


def _with_first(body: bytes, field: int, value: bytes) -> bytes | None:
    """`body` with its first length-delimited field `field` holding `value`,
    re-framed; None when it has none or does not walk."""
    spans = _spans(body)
    hit = next((sp for sp in spans or [] if sp[0] == field), None)
    if hit is None:
        return None
    return body[:hit[1]] + _delimited(field, value) + body[hit[2]:]


def drop_call_operand(dsc: bytes, rule: str) -> bytes | None:
    """`dsc` with one operand removed from a call ([RDSC.4a.9.3]): in the one
    `TerminalNode` (270) whose `rule_name` is `rule`, the first action that is
    an `ACTION_CALL` whose `expr` is a `call` loses its LAST `args` entry. The
    CallExpr, the Expr, the Action and the atom are re-framed. No compiler
    writes a call its op does not admit, so this is how a fixture hands a
    runtime one. None when no or several terminals realize `rule`, none of its
    actions is such a call, the call has no operand, or a body does not walk.
    Not re-sealed. The Mercury runtime's pass, `test_behave.m`, makes the same
    edit with its own walk (`call_operand_dropped`)."""
    name = rule.encode("utf-8")
    terms = [f for f in atom_frames(dsc) if f[0] == TERMINAL_NODE
             and _field(dsc, f[3], f[4], 3, 2) == name]
    if len(terms) != 1:
        return None
    _, frame_start, frame_end, body_start, body_end = terms[0]
    term = dsc[body_start:body_end]
    for num, start, end, action in _spans(term) or []:
        if num != _TERM_ACTIONS or _field(action, 0, len(action),
                                         _ACTION_KIND, 0) != 0:
            continue
        expr = _field(action, 0, len(action), _ACTION_EXPR, 2)
        call = None if expr is None else _field(expr, 0, len(expr),
                                                _EXPR_CALL, 2)
        if call is None:
            continue
        args = [sp for sp in _spans(call) or [] if sp[0] == _CALL_ARGS]
        if not args:
            return None
        short = call[:args[-1][1]] + call[args[-1][2]:]
        new_expr = _with_first(expr, _EXPR_CALL, short)
        new_action = (None if new_expr is None
                      else _with_first(action, _ACTION_EXPR, new_expr))
        if new_action is None:
            return None
        new_term = (term[:start] + _delimited(_TERM_ACTIONS, new_action)
                    + term[end:])
        inner = _delimited(TERMINAL_NODE, new_term)
        return (dsc[:frame_start] + b"\x0a" + _put_varint(len(inner)) + inner
                + dsc[frame_end:])
    return None


# The members that make [RDSC.11.3]'s four load refusals, as
# proto/term.proto and proto/rete_expr.proto lay them out.
_ACTION_ASSIGNS = 4        # Action.assigns
_ASSIGN_EXPR = 2           # SlotAssign.expr
_EXPR_UNOP = 7             # Expr.unop
_UNOP_OPERAND = 2          # UnopExpr.operand; op UNOP_NOT = 0, written absent
_ACTION_CALL = (0,)        # ActionKind ACTION_CALL
_ACTION_ASSERTS = (1, 2)   # ACTION_ASSERT, ACTION_LOGICAL_ASSERT


def _without_first(body: bytes, field: int) -> bytes | None:
    """`body` without its first field `field`; None when it has none or does
    not walk."""
    hit = next((sp for sp in _spans(body) or [] if sp[0] == field), None)
    return None if hit is None else body[:hit[1]] + body[hit[2]:]


def _edit_action(dsc: bytes, rule: str, kinds: tuple[int, ...],
                 edit) -> bytes | None:
    """`dsc` with the first action of `rule`'s one `TerminalNode` whose kind
    is in `kinds` replaced by `edit(action)`, the action and the atom
    re-framed. None when no or several terminals realize `rule`, no action
    has such a kind, `edit` gives None, or a body does not walk. Not
    re-sealed."""
    name = rule.encode("utf-8")
    terms = [f for f in atom_frames(dsc) if f[0] == TERMINAL_NODE
             and _field(dsc, f[3], f[4], 3, 2) == name]
    if len(terms) != 1:
        return None
    _, frame_start, frame_end, body_start, body_end = terms[0]
    term = dsc[body_start:body_end]
    for num, start, end, action in _spans(term) or []:
        if (num != _TERM_ACTIONS
                or _field(action, 0, len(action), _ACTION_KIND, 0) not in kinds):
            continue
        new_action = edit(action)
        if new_action is None:
            return None
        new_term = (term[:start] + _delimited(_TERM_ACTIONS, new_action)
                    + term[end:])
        inner = _delimited(TERMINAL_NODE, new_term)
        return (dsc[:frame_start] + b"\x0a" + _put_varint(len(inner)) + inner
                + dsc[frame_end:])
    return None


def drop_action_expr(dsc: bytes, rule: str) -> bytes | None:
    """`rule`'s first `ACTION_CALL` action without its `expr` ([RDSC.11.3]'s
    third shape). None when it has none. Not re-sealed."""
    return _edit_action(dsc, rule, _ACTION_CALL,
                        lambda a: _without_first(a, _ACTION_EXPR))


def clear_action_expr(dsc: bytes, rule: str) -> bytes | None:
    """`rule`'s first `ACTION_CALL` action with its `expr` an `Expr` of no
    field, so none of its `kind` oneof is set ([RDSC.11.3]'s first shape).
    None when it has no `expr`. Not re-sealed."""
    return _edit_action(dsc, rule, _ACTION_CALL,
                        lambda a: _with_first(a, _ACTION_EXPR, b""))


def drop_assign_expr(dsc: bytes, rule: str) -> bytes | None:
    """The first `SlotAssign` of `rule`'s first `ACTION_ASSERT` or
    `ACTION_LOGICAL_ASSERT` action without its `expr` ([RDSC.11.3]'s second
    shape). None when that action has no assignment or it no `expr`. Not
    re-sealed."""
    def edit(action: bytes) -> bytes | None:
        hit = next((sp for sp in _spans(action) or []
                    if sp[0] == _ACTION_ASSIGNS), None)
        assign = None if hit is None else _without_first(hit[3], _ASSIGN_EXPR)
        if assign is None:
            return None
        return (action[:hit[1]] + _delimited(_ACTION_ASSIGNS, assign)
                + action[hit[2]:])
    return _edit_action(dsc, rule, _ACTION_ASSERTS, edit)


def nest_action_expr(dsc: bytes, rule: str, levels: int) -> bytes | None:
    """`rule`'s first `ACTION_CALL` action with its `expr` E wrapped `levels`
    times as the operand of a `not` (`Expr.unop`, `UnopExpr` with op
    `UNOP_NOT`), so every `Expr` in E sits `levels` deeper ([RDSC.11.3]'s
    fourth shape). None when `levels` is below 1 or the action has no `expr`.
    Not re-sealed."""
    if levels < 1:
        return None

    def edit(action: bytes) -> bytes | None:
        expr = _field(action, 0, len(action), _ACTION_EXPR, 2)
        if expr is None:
            return None
        for _ in range(levels):
            expr = _delimited(_EXPR_UNOP, _delimited(_UNOP_OPERAND, expr))
        return _with_first(action, _ACTION_EXPR, expr)
    return _edit_action(dsc, rule, _ACTION_CALL, edit)


_CALL_OP = 3               # CallExpr.op (proto/rete_expr.proto)


def _call_with_op(expr: bytes, op: int) -> bytes | None:
    """The `Expr` `expr`, a `call`, with that CallExpr's `op` replaced by
    `op`: the old field 3 dropped and the new one written after the call's
    other fields, the Expr re-framed. None when `expr` is no call, the call
    has no `op` written, or a body does not walk."""
    call = _field(expr, 0, len(expr), _EXPR_CALL, 2)
    rest = None if call is None else _without_first(call, _CALL_OP)
    if rest is None:
        return None
    return _with_first(expr, _EXPR_CALL,
                       rest + _put_varint(_CALL_OP << 3) + _put_varint(op))


def set_action_op(dsc: bytes, rule: str, op: int) -> bytes | None:
    """[RCTS.1.2.21]'s `set_action_op` ([RDSC.4a.9.3]): in rule
    `rule`'s one `TerminalNode`, the first `ACTION_CALL` action whose `expr`
    is a `call` has that call's `op` set to `op`, so the op stands as an
    action's `expr`. None when there is no such action. Not re-sealed. The
    Mercury pass, `test_behave.m`, makes the same edit (`action_op_set`)."""
    def edit(action: bytes) -> bytes | None:
        expr = _field(action, 0, len(action), _ACTION_EXPR, 2)
        new_expr = None if expr is None else _call_with_op(expr, op)
        return (None if new_expr is None
                else _with_first(action, _ACTION_EXPR, new_expr))
    return _edit_action(dsc, rule, _ACTION_CALL, edit)


def set_assign_op(dsc: bytes, rule: str, op: int) -> bytes | None:
    """[RCTS.1.2.21]'s `set_assign_op` ([RDSC.4a.9.3]): the call that
    is the `expr` of the first `SlotAssign` of rule `rule`'s first
    `ACTION_ASSERT` or `ACTION_LOGICAL_ASSERT` action has its `op` set to
    `op`, so the op stands inside an expression. None when that assignment's
    `expr` is no call. Not re-sealed. `test_behave.m`'s `assign_op_set`."""
    def edit(action: bytes) -> bytes | None:
        hit = next((sp for sp in _spans(action) or []
                    if sp[0] == _ACTION_ASSIGNS), None)
        if hit is None:
            return None
        assign = hit[3]
        expr = _field(assign, 0, len(assign), _ASSIGN_EXPR, 2)
        new_expr = None if expr is None else _call_with_op(expr, op)
        new_assign = (None if new_expr is None
                      else _with_first(assign, _ASSIGN_EXPR, new_expr))
        if new_assign is None:
            return None
        return (action[:hit[1]] + _delimited(_ACTION_ASSIGNS, new_assign)
                + action[hit[2]:])
    return _edit_action(dsc, rule, _ACTION_ASSERTS, edit)


# The three RETE node atoms (proto/atom.proto), each a body whose field 1 is
# its `node_id`, unique across the three ([RDSC.4a.3]).
ALPHA_NODE = 268
_NODE_ATOMS = (ALPHA_NODE, BETA_NODE, TERMINAL_NODE)


class F64:
    """A `set_field` value written as a `double` is ([RCTS.1.2.21]): wire type
    1 and the 64 `bits`, least significant octet first, so a fixture can hand
    a loader any NaN payload ([RDSC.9.10]).

    A plain class, not a dataclass: scripts/mercury/check.py and pyds's
    tests load this file by path without entering it in `sys.modules`, where
    `dataclass` looks its module up."""
    __slots__ = ("bits",)

    def __init__(self, bits: int) -> None:
        self.bits = bits


def _is_delimited(body: bytes, start: int) -> bool:
    """Whether the field whose key starts at `start` is length-delimited."""
    step = _varint(body, start)
    return step is not None and step[0] & 7 == 2


def _set_in(body: bytes, path: list[int], value) -> bytes | None:
    """`body` with the field `path` names set to `value`: the message each
    (field, occurrence) pair of the path selects, then the last field of it,
    every occurrence of which is removed and, unless `value` is None, written
    once after the message's other fields, as a varint for an int, as a
    fixed64 for an `F64` and as length-delimited bytes for a str. Every
    message on the way is re-framed.
    None when the path has no site: an occurrence the message does not
    carry, a selected field that is not length-delimited, or a field to
    remove that the message does not carry."""
    spans = _spans(body)
    if spans is None:
        return None
    field = path[0]
    if len(path) == 1:
        kept = b"".join(body[s:e] for n, s, e, _ in spans if n != field)
        if value is None:
            return None if len(kept) == len(body) else kept
        if isinstance(value, F64):
            return (kept + _put_varint((field << 3) | 1)
                    + value.bits.to_bytes(8, "little"))
        if isinstance(value, int):
            return kept + _put_varint(field << 3) + _put_varint(value)
        return kept + _delimited(field, value.encode("utf-8"))
    index, rest = path[1], path[2:]
    hits = [sp for sp in spans if sp[0] == field and _is_delimited(body, sp[1])]
    if index >= len(hits):
        return None
    _, start, end, inner = hits[index]
    new_inner = _set_in(inner, rest, value)
    if new_inner is None:
        return None
    return body[:start] + _delimited(field, new_inner) + body[end:]


def set_field(dsc: bytes, node: int | None, path: list[int], value,
              atom: tuple[int, int] | None = None) -> bytes | None:
    """[RCTS.1.2.21]'s `set_field`: in the one `AlphaNode`,
    `BetaNode` or `TerminalNode` whose `node_id` is `node`, or, given `atom`
    (F, I), in occurrence I of the atoms numbered F, the field `path`
    names set to `value` (`_set_in`), the atom re-framed. It reaches what no
    compiler writes: a `node_id` of 0 ([RDSC.4a.3]), an `AlphaNode` naming no
    schema ([RDSC.4a.6]), a malformed `AlphaTest` ([RDSC.4a.6.1]), a slot or
    pattern index past its table ([RDSC.4a.9.1]), a NaN in a `double`
    ([RDSC.9.10]). None when no such atom, or the path has no site. Not
    re-sealed. `test_behave.m` makes the same edit with its own walk
    (`field_set`)."""
    frames = atom_frames(dsc)
    if atom is not None:
        number, occurrence = atom
        hits = [f for f in frames if f[0] == number][occurrence:occurrence + 1]
    else:
        hits = [f for f in frames if f[0] in _NODE_ATOMS
                and _field(dsc, f[3], f[4], 1, 0) == node]
    if len(hits) != 1:
        return None
    num, frame_start, frame_end, body_start, body_end = hits[0]
    new_body = _set_in(dsc[body_start:body_end], path, value)
    if new_body is None:
        return None
    inner = _delimited(num, new_body)
    return (dsc[:frame_start] + b"\x0a" + _put_varint(len(inner)) + inner
            + dsc[frame_end:])


_DSC_HEADER = 263
_HEADER_CAPABILITIES = 13  # DscHeader.capabilities, packed ([RBND.1.3])


def capabilities_edited(dsc: bytes, op: str, index: int) -> bytes | None:
    """`dsc` with the `DscHeader`'s `capabilities` list (field 13, packed)
    made malformed in place, as [RBND.1.3] forbids:
    `duplicate_capability` sets entry `index` + 1 to entry `index`'s value,
    and `swap_capabilities` swaps the two. Every entry must be one varint
    byte, so no length moves. None when the first atom is no `DscHeader`, it
    carries no packed list, an entry is wider than a byte, or there is no
    entry `index` + 1. Not re-sealed. `test_behave.m` makes the same edits
    with its own walk (`capabilities_edited`)."""
    frames = atom_frames(dsc)
    if not frames or frames[0][0] != _DSC_HEADER:
        return None
    _, _, _, start, end = frames[0]
    spans = _spans(dsc[start:end])
    if spans is None:
        return None
    hit = next((s for s in spans if s[0] == _HEADER_CAPABILITIES), None)
    if hit is None:
        return None
    caps = hit[3]
    if (any(b & 0x80 for b in caps) or index < 0
            or index + 1 >= len(caps)):
        return None
    at = start + hit[2] - len(caps)
    edited = bytearray(dsc)
    if op == "duplicate_capability":
        edited[at + index + 1] = caps[index]
    elif op == "swap_capabilities":
        edited[at + index] = caps[index + 1]
        edited[at + index + 1] = caps[index]
    else:
        return None
    return bytes(edited)


def seal(dsc: bytes) -> bytes:
    """`dsc` sealed as the compiler seals it. Bytes with no header field to
    seal come back unchanged."""
    at = sha256_offset(dsc)
    if at is None:
        return dsc
    zeroed = dsc[:at] + bytes(32) + dsc[at + 32:]
    return zeroed[:at] + hashlib.sha256(zeroed).digest() + zeroed[at + 32:]
