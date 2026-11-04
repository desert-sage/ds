# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A nested sub-message length past its container is refused.

`[RDSC.9.7]`: a truncated stream causes the loader to error. `rete_loader.c`
decodes each rete atom through the generated protobuf-c bindings, and
`protobuf_c_message_unpack` refuses a sub-message whose extent does not fit its
container, so the atom body is refused whole rather than decoded with the field
absent.

The input is built by hand rather than found by a fuzzer: an input that can be
written needs no search, and a quiet fuzzer says only what it can reach.

**The control is the point.** `test_unmutated_program_loads` asserts the same
bytes load *before* mutation. Without it, a mutation that lands on the wrong
byte still raises `pyds.Error` and the test passes green while proving nothing —
which is exactly how a check that cannot fail gets written. The error-text
assertion does the other half: `_REFUSALS` below is the accepted set, so a
refusal for another reason — a mutation that landed on an atom no rete decoder
reads, say — does not satisfy it. A bare `pytest.raises(pyds.Error)` would pass
on a wrong-byte mutation and pin nothing.

The bundle comes from `pyds.compile`, which attaches the rete network; each
atom is selected by its oneof tag rather than by position; and the byte to
inflate is identified structurally rather than guessed: in protobuf a
length-delimited field is `<tag><len><bytes>`, so a length prefix is a byte
whose predecessor is a single-byte tag with wire type 2.
"""

import importlib.util
from pathlib import Path

import pyds

# A runtime refuses an artefact whose `dsc_sha256` does not match ([RDSC.3.6]),
# and the check runs before any rete atom is decoded. So every mutated
# bundle below is re-sealed, or its refusal would be the hash's and never the
# decoder's this file is about. The sealer is the harness's, loaded by path
# rather than copied, so there is one definition of where the hash lives.
_SEAL = Path(__file__).resolve().parents[3] / "specs" / "conformance" / "harness" / "dsc_seal.py"
_spec = importlib.util.spec_from_file_location("dsc_seal", _SEAL)
_dsc_seal = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_dsc_seal)
seal = _dsc_seal.seal

# A `where` comparison lowers to a BinopExpr, whose lhs/rhs are nested
# length-delimited sub-messages. Kept minimal so the compiled container is small
# enough to walk byte by byte below.
_SRC = """\
schema Reading scope logical:
    v: Int key

rule hot:
    Reading r where r.v > 10
->
    log info "hot"
"""

# WHICH ATOM carries this program's nested extent is the compiler's lowering's
# to decide, not this test's: `AlphaTest` carries no `Expr` (proto/alfa.proto),
# so `r.v > 10` need not be a `BinopExpr` under AlphaNode, and the AlphaNode may
# carry no `tests` field at all. So this file does not name the atom. It scans
# every atom `rete_loader.c` decodes and requires that at least one nested
# inflation is refused.


def _dsc_bytes() -> bytes:
    """Compile by `pyds.compile`, which is load-bearing here.

    It attaches the AlphaNode/BetaNode/TerminalNode atoms `rete_loader.c`
    reads. A bundle without the rete network holds nothing that loader reads,
    and mutating it would test a container the loader never sees.
    """
    return pyds.compile(_SRC, file="nested_len.ds")


def _read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    """(value, next_pos) — the wire's base-128, as the loader reads it."""
    val = 0
    shift = 0
    while pos < len(buf):
        b = buf[pos]
        pos += 1
        val |= (b & 0x7F) << shift
        if not b & 0x80:
            return val, pos
        shift += 7
    raise AssertionError("varint runs past the end of the buffer")


def _atoms(blob: bytes):
    """Yield (oneof_tag, body_start, body_stop) per top-level atom.

    [RFCS.19.1] — every atom opens 0x0A, then its own length, then the oneof
    tag and the body length.
    """
    pos = 0
    while pos < len(blob):
        assert blob[pos] == 0x0A, f"byte {pos} is not the 0x0A atom tag"
        outer_len, p = _read_varint(blob, pos + 1)
        end = p + outer_len
        tag, p = _read_varint(blob, p)
        body_len, p = _read_varint(blob, p)
        yield tag, p, p + body_len
        pos = end


# The three atom types `rete_loader.c` decodes (proto/atom.proto): AlphaNode
# 268, BetaNode 269, TerminalNode 270. All three are scanned rather than
# AlphaNode alone, because which one carries a given nested extent is a fact
# about the compiler's lowering, not about this test.
_RETE_TAGS = {
    (268 << 3) | 2: "AlphaNode",
    (269 << 3) | 2: "BetaNode",
    (270 << 3) | 2: "TerminalNode",
}

# A refusal that counts. The generated decoder rejects the whole atom body;
# `len` is a hand-written length check's message, for a decoder that has one.
# Anything outside this set is reported, not accepted — see the module
# docstring.
_REFUSALS = ("body protobuf decode failed", "len")


def _rete_bodies(blob: bytes) -> list[tuple[str, int, int]]:
    out = [(_RETE_TAGS[tag], start, stop) for tag, start, stop in _atoms(blob) if tag in _RETE_TAGS]
    assert out, (
        "no AlphaNode/BetaNode/TerminalNode atom in the container — nothing "
        "here reaches "
        "rete_loader.c at all"
    )
    return out


def _length_prefixes(blob: bytes, start: int, stop: int, depth: int = 0) -> list[tuple[int, int]]:
    """Walk a message; return (length-prefix offset, depth) for each length-delimited field.

    The walk descends into each one.

    protobuf-c refuses an over-long extent at any depth, identically. The
    caller keeps depth >= 1 because that is what makes this test's subject the
    nested case; relaxing it would quietly turn a specific pin into a general
    one, and a general one is already covered by the container-level
    truncation tests.

    A flat scan cannot see the depth. It found `schema_name`'s length and one
    false positive inside the string "Reading" — `R` is 0x52, and 0x52 & 7 ==
    2, so ASCII reads as a wire-type-2 tag. Walking the structure instead of
    pattern-matching bytes is what makes the depth known.

    Recursion still descends into string payloads, since nothing here knows
    which length-delimited fields are strings. Those yield junk offsets, which
    is harmless: a junk mutation simply refuses for another reason, and every
    outcome is reported.
    """
    out: list[tuple[int, int]] = []
    i = start
    while i < stop:
        try:
            tag, p = _read_varint(blob, i)
        except AssertionError:
            break
        if tag == 0:
            break
        wt = tag & 0x07
        if wt == 0:  # varint
            try:
                _, p = _read_varint(blob, p)
            except AssertionError:
                break
        elif wt == 1:  # 64-bit
            p += 8
        elif wt == 5:  # 32-bit
            p += 4
        elif wt == 2:  # length-delimited
            lpos = p
            try:
                ln, p = _read_varint(blob, p)
            except AssertionError:
                break
            if p + ln > stop:
                break
            # Single-byte length only, so inflating is a one-for-one swap and
            # every surrounding offset survives.
            if p == lpos + 1 and 1 <= blob[lpos] < 0x80:
                out.append((lpos, depth))
            out.extend(_length_prefixes(blob, p, p + ln, depth + 1))
            p += ln
        else:
            break
        i = p
    return out


def test_unmutated_program_loads():
    """CONTROL. Without this, the mutation test proves nothing."""
    eng = pyds.Engine()
    eng.load_dsc(_dsc_bytes())


def test_nested_length_past_container_is_refused():
    """[RDSC.9.7]: refused, not accepted as an absent field.

    Every candidate is a NESTED length prefix inside a rete atom raised to 127,
    so each declares an extent its container cannot hold. At least one must be
    refused *as a malformed body*, not accepted as an absent field.

    Depth-0 prefixes are excluded deliberately, not for tidiness — see
    `_length_prefixes`: the exclusion is what keeps the subject the nested
    case.

    Every candidate is tried rather than the first, because which one lands on a
    refusable extent depends on a byte layout this test does not own — and a
    test that has to guess the layout right is a test that silently stops
    testing when the layout moves.
    """
    blob = _dsc_bytes()
    bodies = _rete_bodies(blob)
    census = {}
    nested: list[tuple[str, int, int]] = []
    for name, start, stop in bodies:
        found = _length_prefixes(blob, start, stop)
        census[f"{name}@{start}"] = found
        nested += [(name, off, d) for off, d in found if d >= 1]

    assert nested, (
        f"no NESTED length-delimited field in any rete atom.\n"
        f"  prefixes per atom (offset, depth): {census}\n"
        f"Depth 0 is the atom body itself, which this test leaves to the "
        f"container-level truncation checks."
    )

    as_length: list[tuple[str, int, int, str]] = []
    other: list[tuple[str, int, int, str]] = []
    accepted: list[tuple[str, int, int]] = []
    for name, off, d in nested:
        mutated = blob[:off] + bytes([127]) + blob[off + 1 :]
        eng = pyds.Engine()
        try:
            eng.load_dsc(seal(mutated))
        except pyds.Error as exc:
            matched = any(s in str(exc) for s in _REFUSALS)
            (as_length if matched else other).append((name, off, d, str(exc)))
        else:
            accepted.append((name, off, d))

    # Every outcome is reported, including the refusals that did not match, so
    # a failure says what the loader actually objected to.
    assert as_length, (
        f"{len(nested)} nested inflated length(s) across "
        f"{len(bodies)} rete atom(s), none refused for a reason in "
        f"{_REFUSALS}.\n"
        f"  prefixes per atom (offset, depth): {census}\n"
        f"  accepted outright: {accepted}\n"
        f"  refused otherwise: {other}\n"
        f"The refusal comes from protobuf_c_message_unpack returning NULL for "
        f"the whole atom body ([RDSC.9.7])."
    )
