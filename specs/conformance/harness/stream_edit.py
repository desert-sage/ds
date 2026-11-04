# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`replay_refused`'s alterations of a recorded fact stream ([RCTS.1.2.18]).

A stream is the container a `.dsc` is: atoms, each an outer field 1 (`0x0A`,
a length) holding one inner field, the atom's number with wire type 2, a
length and the body ([RFCS.19.1]). Every alteration but `drop_schema_def`,
`drop_fault` and `append_engine_error` keeps every length, so nothing is
re-encoded. Those three remove or add whole atoms; each atom is framed alone,
so the bytes of the rest do not change either.

Not a test module: `runner.py` imports it and `test_runner_codes.py` pins it.
`test_behave.m` makes the same alterations by its own walk, so the two
runtimes are not handed one reading of the stream.
"""
from __future__ import annotations

FACT_ASSERT = 1
FACT_RETRACT = 2
EXTERNAL_ASSERT = 5
SCHEMA_DEF = 256
SLOT = 257
FACT_EMIT = 326

# The fact_id `retract_unknown_fact_id` writes: one varint byte, so the
# FactRetract's length does not move.
UNCARRIED_ID = 0x7F


def _varint(buf: bytes, pos: int) -> tuple[int, int] | None:
    val = shift = 0
    while pos < len(buf) and shift < 64:
        b = buf[pos]
        val |= (b & 0x7F) << shift
        pos += 1
        if not b & 0x80:
            return val, pos
        shift += 7
    return None


def atoms(buf: bytes) -> list[tuple[int, int, int]]:
    """(atom number, body start, body end) of each top-level atom, in order,
    up to the first frame that does not walk."""
    out: list[tuple[int, int, int]] = []
    pos = 0
    while pos < len(buf) and buf[pos] == 0x0A:
        step = _varint(buf, pos + 1)
        if step is None:
            break
        outer_len, inner = step
        end = inner + outer_len
        step = _varint(buf, inner)
        if step is None or step[0] & 7 != 2:
            break
        key, at = step
        step = _varint(buf, at)
        if step is None:
            break
        body_len, body = step
        if body + body_len > end or end > len(buf):
            break
        out.append((key >> 3, body, body + body_len))
        pos = end
    return out


def varint_field_offset(buf: bytes, start: int, end: int,
                        field: int) -> int | None:
    """Where the value of varint field `field` starts in the body
    `buf[start:end]`, or None when the body carries none."""
    pos = start
    while pos < end:
        step = _varint(buf, pos)
        if step is None:
            return None
        key, pos = step
        num, wire = key >> 3, key & 7
        if num == field and wire == 0:
            return pos
        if wire == 0:
            step = _varint(buf, pos)
            if step is None:
                return None
            pos = step[1]
        elif wire == 2:
            step = _varint(buf, pos)
            if step is None:
                return None
            pos = step[1] + step[0]
        elif wire == 1:
            pos += 8
        elif wire == 5:
            pos += 4
        else:
            return None
    return None


def rename_schema(stream: bytes, old: str, new: str) -> bytes | None:
    """Every occurrence of `old`'s bytes replaced by `new`'s, the two of one
    length, so the recording announces and asserts a schema the program does
    not hold ([RFCS.5.4]). None when the names differ in length, are equal or
    empty, or `old` is not in the stream."""
    a, b = old.encode("utf-8"), new.encode("utf-8")
    if not a or len(a) != len(b) or a == b or a not in stream:
        return None
    return stream.replace(a, b)


def retract_unknown_fact_id(stream: bytes) -> bytes | None:
    """The first FactRetract's `fact_id` (field 1) replaced by UNCARRIED_ID,
    an id no FactAssert or FactEmit in the recording carries ([RFCS.7.3]).
    None when there is no FactRetract, its id is not one varint byte, the
    recording carries UNCARRIED_ID, or it holds an ExternalAssert, whose
    `fact_ids` this walk does not read."""
    found = atoms(stream)
    if any(num == EXTERNAL_ASSERT for num, _, _ in found):
        return None
    carried: set[int] = set()
    for num, start, end in found:
        if num in (FACT_ASSERT, FACT_EMIT):
            at = varint_field_offset(stream, start, end, 1)
            step = _varint(stream, at) if at is not None else None
            if step is not None:
                carried.add(step[0])
    if UNCARRIED_ID in carried:
        return None
    target = next(((s, e) for num, s, e in found if num == FACT_RETRACT), None)
    if target is None:
        return None
    at = varint_field_offset(stream, target[0], target[1], 1)
    if at is None or stream[at] & 0x80:
        return None
    edited = bytearray(stream)
    edited[at] = UNCARRIED_ID
    return bytes(edited)


def frames(buf: bytes) -> list[tuple[int, int, int, int, int]] | None:
    """(atom number, frame start, body start, body end, frame end) of every
    top-level atom, or None when a frame does not walk, or the walk does not
    end at the end of `buf`."""
    out: list[tuple[int, int, int, int, int]] = []
    pos = 0
    while pos < len(buf):
        if buf[pos] != 0x0A:
            return None
        step = _varint(buf, pos + 1)
        if step is None:
            return None
        outer_len, inner = step
        end = inner + outer_len
        step = _varint(buf, inner)
        if step is None or step[0] & 7 != 2:
            return None
        key, at = step
        step = _varint(buf, at)
        if step is None:
            return None
        body_len, body = step
        if body + body_len != end or end > len(buf):
            return None
        out.append((key >> 3, pos, body, end, end))
        pos = end
    return out


def string_field(buf: bytes, start: int, end: int, field: int) -> bytes | None:
    """The value of the first length-delimited field `field` in the body
    `buf[start:end]`, or None when the body carries none or does not walk."""
    span = string_span(buf, start, end, field)
    return None if span is None else bytes(buf[span[0]:span[1]])


def string_span(buf: bytes, start: int, end: int,
                field: int) -> tuple[int, int] | None:
    """Where the value of the first length-delimited field `field` in the body
    `buf[start:end]` starts and ends, or None when the body carries none or
    does not walk."""
    pos = start
    while pos < end:
        step = _varint(buf, pos)
        if step is None:
            return None
        key, pos = step
        num, wire = key >> 3, key & 7
        if wire == 2:
            step = _varint(buf, pos)
            if step is None:
                return None
            length, pos = step
            if num == field:
                return pos, pos + length
            pos += length
        elif wire == 0:
            step = _varint(buf, pos)
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


STREAM_HEADER = 258
HEADER_CAPABILITIES = 16  # StreamHeader.capabilities, packed ([RBND.1.3])

# The number `unknown_capability` writes: one varint byte, which
# `proto/capabilities.proto#Capability` does not allocate.
UNALLOCATED_CAPABILITY = 0x7F


def unknown_capability(stream: bytes) -> bytes | None:
    """The first entry of the `StreamHeader`'s `capabilities` (field 16,
    packed) replaced by UNALLOCATED_CAPABILITY, so the header lists a
    number that is no member of `Capability` ([RBND.1.3]). None when
    the recording has no `StreamHeader`, its first carries no packed list,
    or the list's first entry is wider than one varint byte."""
    header = next(((s, e) for num, s, e in atoms(stream)
                   if num == STREAM_HEADER), None)
    if header is None:
        return None
    start, end = header
    pos = start
    while pos < end:
        step = _varint(stream, pos)
        if step is None:
            return None
        key, pos = step
        num, wire = key >> 3, key & 7
        if wire == 2:
            step = _varint(stream, pos)
            if step is None:
                return None
            length, pos = step
            if num == HEADER_CAPABILITIES:
                if length < 1 or stream[pos] & 0x80:
                    return None
                edited = bytearray(stream)
                edited[pos] = UNALLOCATED_CAPABILITY
                return bytes(edited)
            pos += length
        elif wire == 0:
            step = _varint(stream, pos)
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


def drop_schema_def(stream: bytes, schema: str) -> bytes | None:
    """Every SchemaDef and Slot atom whose `schema_name` (field 1 of both) is
    `schema` removed whole, and every FactAssert naming it (field 2) kept, so
    the recording asserts a schema it never announced ([RFCS.5.3],
    [RFCS.5.4]). None when the frames do not walk, `schema` is empty, or the
    recording holds no SchemaDef for it or no FactAssert naming it."""
    found = frames(stream)
    name = schema.encode("utf-8")
    if found is None or not name:
        return None

    def names(num: int, field: int) -> list[tuple[int, int]]:
        return [(fs, fe) for n, fs, bs, be, fe in found
                if n == num and string_field(stream, bs, be, field) == name]

    defs, slots = names(SCHEMA_DEF, 1), names(SLOT, 1)
    if not defs or not names(FACT_ASSERT, 2):
        return None
    out = bytearray()
    pos = 0
    for fs, fe in sorted(defs + slots):
        out += stream[pos:fs]
        pos = fe
    out += stream[pos:]
    return bytes(out)


# Each atom that carries a `timetag`, and the field it is in ([RCTS.1.2.24],
# [RCTS.1.2.18]): RuleFireAnnotation, CallIssued, ComputationError and
# BoundsError. A `timetag` is stream-local and compared by its pairing
# ([RFCS.11.2], [LFST.9.3.6]).
RULE_FIRE_ANNOTATION = 261
TIMETAG_FIELDS = {RULE_FIRE_ANNOTATION: 6, 262: 8, 325: 3, 329: 5}


def _varint_bytes(value: int) -> bytes:
    out = bytearray()
    while True:
        b = value & 0x7F
        value >>= 7
        if value:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def _offset_field(body: bytes, field: int, n: int) -> tuple[bytes, bool] | None:
    """`body` with varint field `field`'s value plus `n` where it is nonzero,
    and whether it was; None when the body does not walk."""
    out = bytearray()
    pos, hit = 0, False
    while pos < len(body):
        step = _varint(body, pos)
        if step is None:
            return None
        key, at = step
        wire = key & 7
        if wire == 0:
            step = _varint(body, at)
            if step is None:
                return None
            value, nxt = step
            if key >> 3 == field and value != 0:
                out += _varint_bytes(key) + _varint_bytes(value + n)
                hit = True
            else:
                out += body[pos:nxt]
        elif wire == 2:
            step = _varint(body, at)
            if step is None:
                return None
            nxt = step[1] + step[0]
            out += body[pos:nxt]
        elif wire in (1, 5):
            nxt = at + (8 if wire == 1 else 4)
            out += body[pos:nxt]
        else:
            return None
        if nxt > len(body):
            return None
        pos = nxt
    return bytes(out), hit


def offset_timetags(stream: bytes, n: int) -> bytes | None:
    """`replay_determinism`'s `timetag_offset` ([RCTS.1.2.24]): every nonzero
    `timetag` the four atoms carry, plus `n`, each atom it changes re-framed,
    since a value's varint may widen. None when the recording carries no
    nonzero `timetag`, or does not walk to its end."""
    out = bytearray()
    pos, changed = 0, False
    for num, start, end in atoms(stream):
        frame = stream[pos:end]
        field = TIMETAG_FIELDS.get(num)
        if field is not None:
            edited = _offset_field(stream[start:end], field, n)
            if edited is None:
                return None
            body, hit = edited
            if hit:
                inner = (_varint_bytes((num << 3) | 2)
                         + _varint_bytes(len(body)) + body)
                frame = b"\x0a" + _varint_bytes(len(inner)) + inner
                changed = True
        out += frame
        pos = end
    if pos != len(stream) or not changed:
        return None
    return bytes(out)


def merge_timetags(stream: bytes, i: int, j: int) -> bytes | None:
    """`replay_refused`'s `merge_timetags` ([RCTS.1.2.18]): the j-th
    RuleFireAnnotation's `timetag`, counting from 0 in stream order, replaced
    by the i-th's wherever one of the four atoms carries it, so two firings
    the engine keeps apart share one `timetag` ([LFST.9.3.6]). Every length
    is kept. None when there is no i-th or j-th annotation, the two already
    share a `timetag`, or their varints differ in width."""
    found = atoms(stream)
    notes = [(s, e) for num, s, e in found if num == RULE_FIRE_ANNOTATION]
    if not 0 <= i < j < len(notes):
        return None
    sites = []
    for s, e in (notes[i], notes[j]):
        at = varint_field_offset(stream, s, e, TIMETAG_FIELDS[RULE_FIRE_ANNOTATION])
        step = _varint(stream, at) if at is not None else None
        if step is None:
            return None
        sites.append((at, step[0], step[1]))
    (ai, vi, ei), (aj, vj, ej) = sites
    if vi == vj or ei - ai != ej - aj:
        return None
    new = stream[ai:ei]
    edited = bytearray(stream)
    for num, s, e in found:
        field = TIMETAG_FIELDS.get(num)
        if field is None:
            continue
        at = varint_field_offset(stream, s, e, field)
        step = _varint(stream, at) if at is not None else None
        if step is not None and step[0] == vj:
            edited[at:step[1]] = new
    return bytes(edited)


CALL_ISSUED = 262


def split_timetag(stream: bytes, index: int) -> bytes | None:
    """`replay_refused`'s `split_timetag` ([RCTS.1.2.18]): the
    `index`-th CallIssued's `timetag`, counting from 0 in stream order,
    replaced by the least nonzero value of the same varint width that none of
    the four atoms carries, so one firing's atoms carry two recorded
    `timetag`s and its one re-derived `timetag` meets a second recorded one
    ([LFST.9.3.6]'s second direction). Every length is kept. None when there
    is no `index`-th CallIssued, its `timetag` is not written, or no value of
    its width is free."""
    found = atoms(stream)
    calls = [(s, e) for num, s, e in found if num == CALL_ISSUED]
    if not 0 <= index < len(calls):
        return None
    start, end = calls[index]
    at = varint_field_offset(stream, start, end, TIMETAG_FIELDS[CALL_ISSUED])
    step = _varint(stream, at) if at is not None else None
    if step is None:
        return None
    width = step[1] - at
    carried = set()
    for num, s, e in found:
        field = TIMETAG_FIELDS.get(num)
        where = varint_field_offset(stream, s, e, field) if field else None
        got = _varint(stream, where) if where is not None else None
        if got is not None:
            carried.add(got[0])
    low = 1 if width == 1 else 1 << (7 * (width - 1))
    free = next((v for v in range(low, 1 << (7 * width)) if v not in carried),
                None)
    if free is None:
        return None
    edited = bytearray(stream)
    edited[at:step[1]] = _varint_bytes(free)
    return bytes(edited)


FACT_WITHDRAW = 327
WITHDRAW_CAUSE = 2  # FactWithdraw.cause ([RFCS.7a.2])


def withdraw_cause(stream: bytes, index: int, cause: int) -> bytes | None:
    """The `index`-th FactWithdraw's `cause` (field 2), counting from 0 in
    stream order, replaced by `cause`, one varint byte, so the recorded
    withdrawal differs from the one the replayer re-derives ([RFCS.7a.2],
    [RFCS.7a.3]). None when there is no `index`-th FactWithdraw, its
    cause is not written (proto3 writes no default) or is wider than one byte,
    or it already is `cause`."""
    withdraws = [(s, e) for num, s, e in atoms(stream) if num == FACT_WITHDRAW]
    if index >= len(withdraws):
        return None
    start, end = withdraws[index]
    at = varint_field_offset(stream, start, end, WITHDRAW_CAUSE)
    if at is None or stream[at] & 0x80 or stream[at] == cause:
        return None
    edited = bytearray(stream)
    edited[at] = cause
    return bytes(edited)


FACT_PUBLISH = 331
# FactPublish's two names ([RFCS.27.1]), by the field each is.
PUBLISH_NAME_FIELDS = {"schema_name": 1, "rule_name": 2}


def publish_name(stream: bytes, index: int, field: str, to: str) -> bytes | None:
    """`replay_refused`'s `publish_name` ([RCTS.1.2.18]): the `index`-th
    FactPublish's `schema_name` or `rule_name`, counting from 0 in stream
    order, replaced by `to`'s UTF-8 octets, so the recorded publish differs
    from the one the replayer re-derives ([RFCS.27.2]). Every length is kept.
    None when `field` names neither, there is no `index`-th FactPublish, the
    field is not written, or `to` is of another length in UTF-8 or the value
    the field already holds."""
    number = PUBLISH_NAME_FIELDS.get(field)
    if number is None:
        return None
    publishes = [(s, e) for num, s, e in atoms(stream) if num == FACT_PUBLISH]
    if index >= len(publishes):
        return None
    span = string_span(stream, *publishes[index], number)
    new = to.encode("utf-8")
    if (span is None or span[1] - span[0] != len(new)
            or stream[span[0]:span[1]] == new):
        return None
    return stream[:span[0]] + new + stream[span[1]:]


CACHE_SEED = 6
# The prelude's atoms, which are no stream event ([RFCS.5.1], [RFCS.26.1]):
# StreamHeader, SchemaDef, Slot and CacheSeed.
PRELUDE_ATOMS = frozenset({STREAM_HEADER, 256, 257, CACHE_SEED})


def seed_after_event(stream: bytes) -> bytes | None:
    """`replay_refused`'s `seed_after_event` ([RCTS.1.2.18]): the first
    CacheSeed's frame moved, whole, to just after the first atom that is no
    prelude atom, so a seed follows an event atom, which no recorder writes
    ([RFCS.26.2]). Every frame keeps its bytes; only the order moves. None
    when the recording has no CacheSeed, or no event atom after it, or does
    not walk to its end."""
    found = atoms(stream)
    if not found or found[-1][2] != len(stream):
        return None
    # Each frame's extent: it starts where the one before it ended.
    starts = [0] + [end for _, _, end in found[:-1]]
    seed = next((i for i, (num, _, _) in enumerate(found)
                 if num == CACHE_SEED), None)
    if seed is None:
        return None
    event = next((i for i, (num, _, _) in enumerate(found)
                  if i > seed and num not in PRELUDE_ATOMS), None)
    if event is None:
        return None
    s_at, s_end, e_end = starts[seed], found[seed][2], found[event][2]
    return (stream[:s_at] + stream[s_end:e_end] + stream[s_at:s_end]
            + stream[e_end:])


# Each fault atom `fault_node` and `drop_fault` take: its number and `node_id`.
FAULT_ATOMS = {"TypeError": (328, 1), "ComputationError": (325, 7)}
ENGINE_ERROR = 330


def fault_node(stream: bytes, atom: str) -> bytes | None:
    """The first `atom`'s `node_id`, one varint byte, raised by one, so the
    recorded fault differs from the one the replayer re-derives ([LFST.9.3.1]).
    None when `atom` is no fault of the set, the recording holds none,
    or its `node_id` is not written, is wider than one byte or is 127."""
    if atom not in FAULT_ATOMS:
        return None
    number, field = FAULT_ATOMS[atom]
    site = next(((s, e) for num, s, e in atoms(stream) if num == number), None)
    at = varint_field_offset(stream, *site, field) if site else None
    if at is None or stream[at] >= 127:
        return None
    edited = bytearray(stream)
    edited[at] += 1
    return bytes(edited)


def drop_fault(stream: bytes, atom: str) -> bytes | None:
    """The first `atom`'s frame removed, so the replayer re-derives a fault the
    recording lacks ([LFST.9.3.1]). None when `atom` is no fault of the
    set, the recording holds none, or it does not walk to its end."""
    if atom not in FAULT_ATOMS:
        return None
    found = atoms(stream)
    if not found or found[-1][2] != len(stream):
        return None
    number = FAULT_ATOMS[atom][0]
    at = next((i for i, (num, _, _) in enumerate(found) if num == number), None)
    if at is None:
        return None
    start = found[at - 1][2] if at else 0
    return stream[:start] + stream[found[at][2]:]


def append_engine_error(stream: bytes) -> bytes | None:
    """An EngineError added after the last atom: fault 1, seq 999, rule_name
    `r`, so the recording holds a fault the replayer does not raise ([RFCS.6.7]).
    None when the recording does not walk to its end or holds one."""
    found = atoms(stream)
    if not found or found[-1][2] != len(stream):
        return None
    if any(num == ENGINE_ERROR for num, _, _ in found):
        return None
    body = b"\x08\x01\x20\xe7\x07\x2a\x01r"
    inner = (_varint_bytes(ENGINE_ERROR << 3 | 2) + _varint_bytes(len(body))
             + body)
    return stream + b"\x0a" + _varint_bytes(len(inner)) + inner


def _whole(value, low: int, high: int | None = None) -> bool:
    """An integer, not a bool, from `low` (to `high`)."""
    return (isinstance(value, int) and not isinstance(value, bool)
            and value >= low and (high is None or value <= high))


def mutate(stream: bytes, mutation) -> bytes | None:
    """`mutation`, one member of [RCTS.1.2.18]'s closed set, applied to
    `stream`; None when it names no member or has no site."""
    if not isinstance(mutation, dict):
        return None
    op = mutation.get("op")
    if op == "withdraw_cause" and set(mutation) == {"op", "index", "cause"}:
        index, cause = mutation["index"], mutation["cause"]
        if _whole(index, 0) and _whole(cause, 1, 127):
            return withdraw_cause(stream, index, cause)
        return None
    if op == "publish_name" and set(mutation) == {"op", "index", "field", "to"}:
        index, field, to = mutation["index"], mutation["field"], mutation["to"]
        if _whole(index, 0) and isinstance(field, str) and isinstance(to, str):
            return publish_name(stream, index, field, to)
        return None
    if op == "rename_schema" and set(mutation) == {"op", "from", "to"}:
        old, new = mutation["from"], mutation["to"]
        if isinstance(old, str) and isinstance(new, str):
            return rename_schema(stream, old, new)
        return None
    if op == "retract_unknown_fact_id" and set(mutation) == {"op"}:
        return retract_unknown_fact_id(stream)
    if op == "drop_schema_def" and set(mutation) == {"op", "schema"}:
        if isinstance(mutation["schema"], str):
            return drop_schema_def(stream, mutation["schema"])
        return None
    if op == "unknown_capability" and set(mutation) == {"op"}:
        return unknown_capability(stream)
    if op == "seed_after_event" and set(mutation) == {"op"}:
        return seed_after_event(stream)
    if op == "fault_node" and set(mutation) == {"op", "atom"}:
        if isinstance(mutation["atom"], str):
            return fault_node(stream, mutation["atom"])
        return None
    if op == "drop_fault" and set(mutation) == {"op", "atom"}:
        if isinstance(mutation["atom"], str):
            return drop_fault(stream, mutation["atom"])
        return None
    if op == "append_engine_error" and set(mutation) == {"op"}:
        return append_engine_error(stream)
    if op == "split_timetag" and set(mutation) == {"op", "atom"}:
        if _whole(mutation["atom"], 0):
            return split_timetag(stream, mutation["atom"])
        return None
    if op == "merge_timetags" and set(mutation) == {"op", "firings"}:
        firings = mutation["firings"]
        if (isinstance(firings, list) and len(firings) == 2
                and all(isinstance(f, int) and not isinstance(f, bool)
                        for f in firings)):
            return merge_timetags(stream, firings[0], firings[1])
        return None
    return None
