# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`field_order`'s check of a recorded fact stream ([RCTS.1.2.19]).

[RFCS.19.5]: a writer writes the fields of every message it emits in ascending
field-number order, each atom body and every message nested in one, a fact
body included, and a field that is not repeated at most once. Both are
properties of the bytes, so they are checked here on one recording.

The walk knows each message's fields from `proto/*.proto`, read by this
module's own parser (`table`), never from a runtime: the wire is spec,
and neither writer is handed its own reading of it. From
the root `Stream`, every length-delimited field whose type is a message is
walked as that message. A fact body (`FactAssert.fact`, `FactEmit.fact`) is a
`bytes` field holding a message typed by its `SchemaDef`, one scalar field per
slot and none repeated ([RDSC.5.8.3]), so it is walked as a flat message whose
fields must strictly ascend.

`test_behave.m` walks the Mercury runtime's recording by the same table,
which `scripts/private/gate/gate.py` stages beside its corpus (`--table`), with its own code.

Not a test module: `runner.py` imports it and `test_field_order.py` pins it.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

PROTO_DIR = Path(__file__).resolve().parents[3] / "proto"
ROOT = "Stream"

# The two `bytes` fields that hold a fact body ([RFCS.6.2], [RFCS.6a]).
FACT_FIELDS = (("FactAssert", 3), ("FactEmit", 3))
FACT = "@fact"

_SCALARS = frozenset({
    "double", "float", "int32", "int64", "uint32", "uint64", "sint32",
    "sint64", "fixed32", "fixed64", "sfixed32", "sfixed64", "bool",
    "string", "bytes"})

_TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_.]*|\d+|\"(?:[^\"\\]|\\.)*\"|\S")
_COMMENTS = re.compile(r"//[^\n]*|/\*.*?\*/", re.DOTALL)

# One field: (number, repeated, type). The type is "" for a scalar or an enum,
# FACT for a fact body, or the name of the message it holds.
Field = tuple[int, bool, str]


class ProtoError(ValueError):
    """A `.proto` this parser cannot read: a construct outside the subset
    `proto/` uses, or a type name that resolves to nothing."""


def _parse_block(toks: list[str], i: int, scope: str,
                 raw: dict[str, list[tuple[int, bool, str]]],
                 enums: set[str]) -> int:
    """Parse declarations from `toks[i]` up to the `}` that closes `scope`
    (or the end, at top level). Returns the index after it."""
    while i < len(toks):
        t = toks[i]
        if t == "}":
            return i + 1
        if t == ";":
            i += 1
        elif t in ("syntax", "package", "import", "option", "reserved",
                   "extensions"):
            while toks[i] != ";":
                i += 1
            i += 1
        elif t in ("message", "enum"):
            name = f"{scope}.{toks[i + 1]}" if scope else toks[i + 1]
            if toks[i + 2] != "{":
                raise ProtoError(f"{t} {name}: no body")
            if t == "enum":
                if name in enums or name in raw:
                    raise ProtoError(f"{name} declared twice")
                enums.add(name)
                depth, i = 1, i + 3
                while depth:
                    depth += {"{": 1, "}": -1}.get(toks[i], 0)
                    i += 1
            else:
                if name in raw or name in enums:
                    raise ProtoError(f"{name} declared twice")
                raw[name] = []
                i = _parse_block(toks, i + 3, name, raw, enums)
        elif t == "oneof":
            if toks[i + 2] != "{":
                raise ProtoError(f"oneof {toks[i + 1]} in {scope}: no body")
            # A oneof's members are fields of the enclosing message.
            i = _parse_block(toks, i + 3, scope, raw, enums)
        elif scope and t in ("map", "group", "extend", "service"):
            raise ProtoError(f"{scope}: `{t}` is outside the subset read here")
        elif scope:
            repeated = t == "repeated"
            if t in ("repeated", "optional"):
                i += 1
            ftype, _name, eq, num = toks[i:i + 4]
            if eq != "=" or not num.isdigit():
                raise ProtoError(f"{scope}: cannot read the field at `{t}`")
            i += 4
            if toks[i] == "[":
                while toks[i] != "]":
                    i += 1
                i += 1
            if toks[i] != ";":
                raise ProtoError(f"{scope}.{_name}: no `;`")
            raw[scope].append((int(num), repeated, ftype))
            i += 1
        else:
            raise ProtoError(f"top level: cannot read `{t}`")
    if scope:
        raise ProtoError(f"{scope}: no closing `}}`")
    return i


def _resolve(ftype: str, scope: str, raw: dict, enums: set[str]) -> str:
    """The table type of field type `ftype` named inside message `scope`:
    "" for a scalar or an enum, else the message's full name. Names resolve
    innermost scope first, as protoc resolves them."""
    if ftype in _SCALARS:
        return ""
    parts = scope.split(".")
    for n in range(len(parts), -1, -1):
        cand = ".".join(parts[:n] + [ftype])
        if cand in raw:
            return cand
        if cand in enums:
            return ""
    raise ProtoError(f"{scope}: the type `{ftype}` resolves to nothing")


def table(proto_dir: Path = PROTO_DIR) -> dict[str, dict[int, Field]]:
    """Every message in `proto_dir`'s `.proto` files, by full name, as its
    fields by number. The two fact-body fields are typed FACT."""
    return table_of({p.name: p.read_text(encoding="utf-8")
                     for p in sorted(proto_dir.glob("*.proto"))})


def table_of(files: dict[str, str]) -> dict[str, dict[int, Field]]:
    """`table` over `.proto` texts given by file name."""
    raw: dict[str, list[tuple[int, bool, str]]] = {}
    enums: set[str] = set()
    for name, text in sorted(files.items()):
        try:
            _parse_block(_TOKEN.findall(_COMMENTS.sub(" ", text)), 0, "", raw,
                         enums)
        except (ProtoError, IndexError) as exc:
            raise ProtoError(f"{name}: {exc}") from exc
    out: dict[str, dict[int, Field]] = {}
    for msg, fields in raw.items():
        out[msg] = {}
        for num, repeated, ftype in fields:
            if num in out[msg]:
                raise ProtoError(f"{msg}: field {num} declared twice")
            out[msg][num] = (num, repeated, _resolve(ftype, msg, raw, enums))
    for msg, num in FACT_FIELDS:
        field = out.get(msg, {}).get(num)
        if field is None or field[2] != "" or field[1]:
            raise ProtoError(f"{msg}.{num} is not the scalar `bytes` fact body "
                             f"this walk reads as one ([RFCS.19.5])")
        out[msg][num] = (num, False, FACT)
    if ROOT not in out:
        raise ProtoError(f"no message `{ROOT}` to walk a recording from")
    return out


def table_json(tab: dict[str, dict[int, Field]]) -> str:
    """The table as `test_behave.m` reads it: `{"root": R, "messages":
    {name: [[number, repeated, type], ...]}}`, fields ascending."""
    return json.dumps({
        "root": ROOT,
        "messages": {m: [list(f) for _, f in sorted(fs.items())]
                     for m, fs in sorted(tab.items())},
    }, indent=1, sort_keys=True) + "\n"


def _varint(buf: bytes, pos: int, end: int) -> tuple[int, int] | None:
    val = shift = 0
    while pos < end and shift < 64:
        b = buf[pos]
        val |= (b & 0x7F) << shift
        pos += 1
        if not b & 0x80:
            return val, pos
        shift += 7
    return None


def _skip(buf: bytes, pos: int, end: int, wire: int) -> tuple[int, int] | None:
    """(value start, value end) of a field whose key ends at `pos`, or None
    when it runs past `end` or its wire type is not one proto3 writes."""
    if wire == 0:
        step = _varint(buf, pos, end)
        return None if step is None else (pos, step[1])
    if wire == 1:
        return (pos, pos + 8) if pos + 8 <= end else None
    if wire == 5:
        return (pos, pos + 4) if pos + 4 <= end else None
    if wire == 2:
        step = _varint(buf, pos, end)
        if step is None or step[1] + step[0] > end:
            return None
        return step[1], step[1] + step[0]
    return None


def _walk(buf: bytes, start: int, end: int, msg: str,
          tab: dict[str, dict[int, Field]], path: str,
          out: list[str]) -> None:
    fields = tab[msg]
    prev = 0
    pos = start
    nth = 0
    while pos < end:
        step = _varint(buf, pos, end)
        if step is None:
            out.append(f"{path}: the key at byte {pos} does not decode")
            return
        key, pos = step
        num, wire = key >> 3, key & 7
        field = fields.get(num)
        if num < prev:
            out.append(f"{path}: field {num} after field {prev}")
        elif num == prev and not (field and field[1]):
            out.append(f"{path}: field {num} twice, and {msg}.{num} is not "
                       f"repeated")
        prev = max(prev, num)
        span = _skip(buf, pos, end, wire)
        if span is None:
            out.append(f"{path}: field {num} (wire type {wire}) does not "
                       f"decode at byte {pos}")
            return
        pos = span[1]
        if field is None:
            out.append(f"{path}: field {num} is not a field of {msg}")
            continue
        ftype = field[2]
        if ftype and wire != 2:
            out.append(f"{path}: field {num} holds a {ftype} with wire type "
                       f"{wire}")
        elif ftype == FACT:
            _walk_fact(buf, span[0], span[1], f"{path} > {msg}.fact", out)
        elif ftype:
            if msg == ROOT:
                sub = f"atom {nth}"
                nth += 1
            elif msg == "Atom":
                sub = f"{path} ({ftype})"
            else:
                sub = f"{path} > {msg}.{num}"
            _walk(buf, span[0], span[1], ftype, tab, sub, out)


def _walk_fact(buf: bytes, start: int, end: int, path: str,
               out: list[str]) -> None:
    """A fact body: one scalar field per slot, none repeated, so each field
    number is greater than the one before."""
    prev = 0
    pos = start
    while pos < end:
        step = _varint(buf, pos, end)
        if step is None:
            out.append(f"{path}: the key at byte {pos} does not decode")
            return
        key, pos = step
        num, wire = key >> 3, key & 7
        if num <= prev:
            out.append(f"{path}: slot field {num} after field {prev}")
        prev = max(prev, num)
        span = _skip(buf, pos, end, wire)
        if span is None:
            out.append(f"{path}: slot field {num} does not decode at byte "
                       f"{pos}")
            return
        pos = span[1]


def problems(stream: bytes, tab: dict[str, dict[int, Field]]) -> list[str]:
    """Every place `stream` breaks [RFCS.19.5]'s ascending order or its
    at-most-once rule, in stream order; empty when it keeps both."""
    out: list[str] = []
    _walk(stream, 0, len(stream), ROOT, tab, "stream", out)
    return out


def atom_names(stream: bytes, tab: dict[str, dict[int, Field]]) -> set[str]:
    """The message name of every atom in `stream`, by the `Atom` oneof's
    field numbers; an atom whose number the oneof does not hold names
    nothing."""
    from stream_edit import atoms
    oneof = tab["Atom"]
    return {oneof[num][2] for num, _, _ in atoms(stream) if num in oneof}


def _fields(buf: bytes, start: int, end: int) -> list[tuple[int, int, int]]:
    """(field number, start, end) of each top-level field of the message
    `buf[start:end]`, up to the first that does not decode."""
    out = []
    pos = start
    while pos < end:
        step = _varint(buf, pos, end)
        if step is None:
            break
        key, at = step
        span = _skip(buf, at, end, key & 7)
        if span is None:
            break
        out.append((key >> 3, pos, span[1]))
        pos = span[1]
    return out


def swapped(stream: bytes) -> bytes | None:
    """`stream` with the first two fields of the first atom body that has two
    of different numbers swapped in place: every length is kept, and the body
    now breaks ascending order. The check must refuse it, or it is not shown
    to fire ([RCTS.1.2.19]). None when no atom body has two such fields."""
    from stream_edit import atoms
    for _num, start, end in atoms(stream):
        fs = _fields(stream, start, end)
        if len(fs) >= 2 and fs[0][0] != fs[1][0]:
            (_, a, b), (_, _b, c) = fs[0], fs[1]
            return stream[:a] + stream[b:c] + stream[a:b] + stream[c:]
    return None


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[0] == "--table":
        Path(argv[1]).write_text(table_json(table()), encoding="utf-8")
        return 0
    if len(argv) == 1:
        found = problems(Path(argv[0]).read_bytes(), table())
        for line in found:
            print(line)
        print(f"field_order: {len(found)} problem(s)")
        return 1 if found else 0
    print("usage: field_order.py --table OUT.json | field_order.py STREAM",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
