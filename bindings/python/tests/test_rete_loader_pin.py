# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""[RDSC.10.9] pin — `rete_loader.c`'s field numbers are `rete_expr.proto`'s.

`runtime/src/libds/dsc/rete_loader.c` decodes `Expr` through the generated
protobuf-c bindings, so the tie holds by construction. This file is the
evidence that it does, and it fails if a change walks back to a hand-written
path: a `switch (fn)` with one hand-typed `case` per `oneof` arm has seventeen
chances to drift from the proto with nothing to notice.

WHY THIS IS BEHAVIOURAL AND NOT A SOURCE GREP
---------------------------------------------
Everything below is written against BEHAVIOUR at the wire, so it does not need
to know how the decoder is built. A test that grepped `case 8:` out of the C
would die with the line it checks.

WHAT [RDSC.10.9] REQUIRES
-------------------------
Failure "if a field number, wire type or `oneof` membership diverges."
`Expr` is a 17-arm `oneof`, so this file covers all three — and `oneof`
membership is exactly where a hand-typed switch drifts.

All three dimensions fall out of ONE construction, described below, which is
what makes them comparable to each other.

THE CONSTRUCTION
----------------
Splice an extra `Expr` arm into a compiled bundle:

    call = 8  ->  CallExpr { op = 999999 }        (proto/rete_expr.proto)

999999 is not a `BuiltinFn`, and `rete_loader.c` rejects an unknown builtin op
**at load**, with a message no other site emits. So an arm
the decoder resolves as `call` and lets win is a *refusal we can name*, while an
arm it drops is a silent success. That asymmetry is the whole instrument:

  * **appended, field 8, wire type 2** -> must be REFUSED.
    Locates a real `Expr` (nothing else in the container turns field 8 into a
    builtin-op lookup) and shows the arm won as the last one on the wire.
  * **appended, field 20, wire type 2** -> must LOAD.
    Field number. 20 is not in `Expr`'s `oneof`, so `[RDSC.10.6]` says skip it.
    A decoder that answered to any number, or matched the payload shape rather
    than the tag, would refuse this too.
  * **appended, field 8, wire type 0** -> must be REFUSED.
    Wire type. Field 8 is a message; a varint under that number is not a
    `CallExpr`. A decoder that answered a wire-type mismatch by skipping the
    field would load it, and the divergence would be invisible.
  * **PREPENDED, field 8, wire type 2** -> must LOAD.
    `oneof` membership. Two arms are now set; protobuf says the LAST one wins
    and the earlier is discarded, not merged. So the same bytes that refuse
    when appended must load when they come first, because the program's own
    arm follows them. A decoder that treated the seventeen arms as seventeen
    independent struct fields — which is what a hand-written switch
    structurally is — would look up the bogus op either way and refuse both.

The last two are the same six bytes at the same extent, differing only in which
side they land on. That is deliberate: it removes every explanation for a
difference in outcome except arm ordering.

WHY THE EXTENT IS SEARCHED FOR AND NOT NAMED
--------------------------------------------
Which atom carries an `Expr` is the compiler's lowering's to decide:
`AlphaTest` carries no `Expr`, and the AlphaNode atom for a one-pattern rule
may have no `tests` field at all. So this file scans every length-delimited
extent inside every AlphaNode/BetaNode/TerminalNode atom and lets the loader's
own error message say which ones were `Expr` bodies. Every outcome is reported
on failure, including the refusals that did not match.
"""

import importlib.util
from pathlib import Path

import pytest

import pyds

# A runtime refuses an artefact whose `dsc_sha256` does not match ([RDSC.3.6]),
# before any rete atom is decoded. So every spliced bundle below goes
# through `_load_edited`, which re-seals it, or every splice would be refused
# for its hash and none would reach the `Expr` decoder. The control loads the
# compiler's own bytes unsealed by this file. The sealer is the harness's,
# loaded by path rather than copied.
_SEAL = Path(__file__).resolve().parents[3] / "specs" / "conformance" / "harness" / "dsc_seal.py"
_spec = importlib.util.spec_from_file_location("dsc_seal", _SEAL)
_dsc_seal = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_dsc_seal)

# Lifted verbatim from bindings/python/tests/grammar_samples/09_negation_and_within.ds
# (`no_motion_after_door`), so the syntax is not this file's problem to get
# right — a compile error here would read as a missing Expr and send the next
# reader after the loader.
#
# It carries TWO independent sources of `Expr`, because one that turned out not
# to be an `Expr` would leave nothing to measure at:
#
#   * `m.location == d.zone` spans two patterns, so it cannot lower to an alpha
#     test and becomes a BetaNode join `Expr`. A single-pattern rule would not do:
#     `AlphaTest` carries no `Expr` at all.
#   * `"{d.zone}"` interpolates, giving the TerminalNode RHS an `Expr` of its own.
_SRC = """\
schema DoorOpen scope ttl 1_h:
    ts: Time
    zone: String

schema Motion scope ttl 1_h:
    ts: Time
    location: String

rule motion_after_door:
    DoorOpen d
    then Motion m within 30_s where m.location == d.zone
->
    log info "motion confirmed at {d.zone}"
"""

# proto/atom.proto — the three atoms rete_loader.c decodes.
_RETE_TAGS = {
    (268 << 3) | 2: "AlphaNode",
    (269 << 3) | 2: "BetaNode",
    (270 << 3) | 2: "TerminalNode",
}

# proto/rete_expr.proto: `CallExpr call = 8` in Expr's oneof; `BuiltinFn op = 3`
# in CallExpr (field 1 is `reserved`).
_CALL_FN = 8
_OP_FN = 3
# Not a BuiltinFn. `ds_lookup_fn` returns NULL and rete_loader.c refuses the
# load. Chosen large so no future enum allocation can quietly make it valid.
_BOGUS_OP = 999_999
# Not a member of Expr's oneof, which runs 1..17. `[RDSC.10.6]` says skip it.
_UNUSED_FN = 20

# The one refusal text only rete_loader.c's builtin-op lookup emits.
_OP_REFUSAL = "unknown builtin op"


def _varint(v: int) -> bytes:
    out = bytearray()
    while True:
        b = v & 0x7F
        v >>= 7
        out.append(b | 0x80 if v else b)
        if not v:
            return bytes(out)


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


def _call_arm(field_no: int, wire_type: int) -> bytes:
    """Return an `Expr` arm carrying CallExpr{op=999999}, under a chosen tag.

    `wire_type` is a parameter because the wire-type dimension needs the same
    field number to appear under the wrong one. At wire type 0 the message is
    not encodable as a message at all, so the payload degenerates to the op
    varint alone — which is the point: nothing about those bytes is a CallExpr
    except the field number, and the decoder must object to that.
    """
    tag = _varint((field_no << 3) | wire_type)
    if wire_type == 0:
        return tag + _varint(_BOGUS_OP)
    body = _varint((_OP_FN << 3) | 0) + _varint(_BOGUS_OP)
    return tag + _varint(len(body)) + body


def _atoms(blob: bytes):
    """Yield (oneof_tag, [outer_len_off, body_len_off], body_start, body_stop).

    [RFCS.19.1] — every atom opens 0x0A, then its own length, then the oneof tag
    and the body length. Both lengths enclose anything spliced into the body, so
    both are part of the fixup chain.
    """
    pos = 0
    while pos < len(blob):
        assert blob[pos] == 0x0A, f"byte {pos} is not the 0x0A atom tag"
        outer_off = pos + 1
        outer_len, p = _read_varint(blob, outer_off)
        end = p + outer_len
        _tag, p = _read_varint(blob, p)
        body_off = p
        body_len, p = _read_varint(blob, body_off)
        yield _tag, [outer_off, body_off], p, p + body_len
        pos = end


def _extents(
    blob: bytes, start: int, stop: int, chain: list[int]
) -> list[tuple[list[int], int, int]]:
    """Every length-delimited extent in [start, stop), with its enclosing chain.

    `chain` is the list of length-prefix offsets from the atom framing inwards,
    ending with the extent's own — precisely the prefixes `_splice` has to widen.

    Recursion descends into string payloads too, since nothing here knows which
    length-delimited fields are strings; those yield junk extents. Harmless: a
    junk splice simply fails to produce the CALL refusal and is reported as
    such. Filtering them by guesswork is what would make this fragile.
    """
    out: list[tuple[list[int], int, int]] = []
    i = start
    while i < stop:
        try:
            tag, p = _read_varint(blob, i)
        except AssertionError:
            break
        if tag == 0:
            break
        wt = tag & 0x07
        if wt == 0:
            try:
                _, p = _read_varint(blob, p)
            except AssertionError:
                break
        elif wt == 1:
            p += 8
        elif wt == 5:
            p += 4
        elif wt == 2:
            lpos = p
            try:
                ln, p = _read_varint(blob, lpos)
            except AssertionError:
                break
            if p + ln > stop:
                break
            sub = [*chain, lpos]
            out.append((sub, p, p + ln))
            out.extend(_extents(blob, p, p + ln, sub))
            p += ln
        else:
            break
        i = p
    return out


def _splice(blob: bytes, at: int, ins: bytes, chain: list[int]) -> bytes:
    """Insert `ins` at `at`, widening every enclosing length prefix.

    INNERMOST FIRST, and that ordering is not cosmetic. A length prefix is
    itself a varint: growing a body from 127 to 133 bytes turns a one-byte
    prefix into two, and those extra bytes are *inside* every prefix further
    out. So the delta carried outwards is the payload growth plus however much
    the prefixes already rewritten grew. Fixing the chain outermost-first would
    under-count by exactly that, and produce a container whose outer lengths
    stop short of their own contents — a truncation this test would then
    mistake for a decoder refusal.
    """
    edits: dict[int, tuple[int, bytes]] = {}
    delta = len(ins)
    for off in reversed(chain):
        val, nxt = _read_varint(blob, off)
        old_width = nxt - off
        new = _varint(val + delta)
        edits[off] = (old_width, new)
        delta += len(new) - old_width

    out = bytearray()
    cursor = 0
    for off in sorted(edits):
        old_width, new = edits[off]
        out += blob[cursor:off]
        out += new
        cursor = off + old_width
    assert cursor <= at, (
        f"splice point {at} precedes a length prefix at {cursor}; the chain is "
        f"supposed to enclose it"
    )
    out += blob[cursor:at]
    out += ins
    out += blob[at:]
    return bytes(out)


@pytest.fixture(scope="module")
def bundle() -> bytes:
    """Compile by the supported path.

    `pyds.compile` attaches the AlphaNode/BetaNode/TerminalNode atoms, and a
    bundle without them reaches `rete_loader.c` not at all.
    """
    return pyds.compile(_SRC, file="rete_pin.ds")


@pytest.fixture(scope="module")
def rete_extents(bundle) -> list[tuple[list[int], int, int]]:
    found: list[tuple[list[int], int, int]] = []
    for tag, chain, start, stop in _atoms(bundle):
        if tag in _RETE_TAGS:
            found.extend(_extents(bundle, start, stop, chain))
    assert found, (
        "no length-delimited extent in any AlphaNode/BetaNode/TerminalNode "
        "atom — nothing here reaches rete_loader.c's Expr decoder at all"
    )
    return found


def _load(blob: bytes) -> str | None:
    """None on a clean load, else the refusal text."""
    try:
        pyds.Engine().load_dsc(blob)
    except pyds.Error as exc:
        return str(exc)
    return None


def _load_edited(blob: bytes) -> str | None:
    """`_load` of a spliced bundle, re-sealed first, as the compiler seals."""
    return _load(_dsc_seal.seal(blob))


@pytest.fixture(scope="module")
def expr_site(bundle, rete_extents) -> tuple[list[int], int, int]:
    """Find the first extent where an appended `call = 8` arm becomes a CALL refusal.

    This is the CONTROL for everything below, and it does double duty: it proves
    an `Expr` body was actually found, and it proves the appended arm WON — a
    decoder that kept the first arm set would never reach the op lookup.

    Located rather than named. Which extent is an `Expr` is a fact about the
    compiler's lowering, and a test that has to guess it right is a test that
    silently stops testing when the lowering moves.

    EMPTY EXTENTS ARE SKIPPED, and not for tidiness. In an empty body the
    spliced arm is the ONLY arm, so it wins from either end — and the `oneof`
    test below, which reads "refuses appended, loads prepended", would see
    "refuses both" and report a divergence that is really just an empty
    message. The one candidate that cannot discriminate is the one that would
    produce a false positive.
    """
    other: list[tuple[int, str]] = []
    accepted: list[int] = []
    empty: list[int] = []
    for chain, start, stop in rete_extents:
        if stop == start:
            empty.append(start)
            continue
        text = _load_edited(_splice(bundle, stop, _call_arm(_CALL_FN, 2), chain))
        if text is None:
            accepted.append(start)
        elif _OP_REFUSAL in text:
            return chain, start, stop
        else:
            other.append((start, text))

    raise AssertionError(
        f"appended `call = 8` {{op = {_BOGUS_OP}}} to {len(rete_extents)} "
        f"extent(s); none refused as an unknown builtin op.\n"
        f"  loaded clean: {accepted}\n"
        f"  refused otherwise: {other}\n"
        f"  skipped as empty: {empty}\n"
        f"Either no extent scanned is an Expr body, or the last arm on the "
        f"wire did not win. rete_loader.c's op lookup is the only site that emits "
        f"{_OP_REFUSAL!r}."
    )


def test_unmutated_bundle_loads(bundle):
    """CONTROL. Without this, every mutation below proves nothing."""
    assert _load(bundle) is None


def test_an_expr_body_is_reachable(expr_site):
    """CONTROL. Names the extent the three dimensions are measured at.

    Fails via the fixture, whose message reports every extent and every refusal.
    """
    _chain, start, stop = expr_site
    assert stop > start


def test_field_number_divergence_is_observable(bundle, expr_site):
    """[RDSC.10.9] — field 20 is not `call`, and must be skipped, not decoded.

    Same payload, same position, same length fixups as the arm that refuses at
    field 8. Only the field number differs, so a refusal here would mean the
    decoder resolved `call` from something other than the proto's number — and a
    clean load means it did not.

    This is also the `[RDSC.10.6]` half: an unknown field is skipped. That
    cannot be the whole discharge — a correct skip and a decoder gone stale look
    identical at the wire — but paired with the field-8 refusal it does pin the
    boundary between them.
    """
    chain, _start, stop = expr_site
    text = _load_edited(_splice(bundle, stop, _call_arm(_UNUSED_FN, 2), chain))
    assert text is None, (
        f"field {_UNUSED_FN} is not in Expr's oneof and must be skipped "
        f"([RDSC.10.6]); the loader refused instead: {text}"
    )


def test_wire_type_divergence_is_observable(bundle, expr_site):
    """[RDSC.10.9] — field 8 as a varint is not a `CallExpr`.

    `Expr.call` is a message: wire type 2. Under wire type 0 the bytes cannot be
    a `CallExpr`, and a decoder tied to the proto says so. A decoder that read
    `wt` out of the tag and answered a mismatch by skipping the field would drop
    the arm and load the bundle, and this assertion would fail.
    """
    chain, _start, stop = expr_site
    assert _load_edited(_splice(bundle, stop, _call_arm(_CALL_FN, 0), chain)) is not None


def test_oneof_membership_is_observable(bundle, expr_site):
    """[RDSC.10.9] — two arms set: the LAST one wins and the first is discarded.

    These are the same six bytes that `expr_site` established are refused when
    appended. Moved to the front of the same extent they must LOAD, because the
    program's own arm now follows them and a `oneof` keeps only the last. The
    bogus op is still on the wire; it is simply no longer the arm that won, and
    the decoder must never look it up.

    protobuf-c owns the rule. A hand-written switch is structurally seventeen
    independent assignments, which lands on protobuf's semantics only by
    accident; this pins the semantics whichever decoder is in place.
    """
    chain, start, _stop = expr_site
    text = _load_edited(_splice(bundle, start, _call_arm(_CALL_FN, 2), chain))
    assert text is None or _OP_REFUSAL not in text, (
        f"the bogus `call` arm is FIRST, so the program's own arm is last and "
        f"must win — but the loader looked the op up anyway: {text}\n"
        f"That is a oneof-membership divergence: the arms are being merged "
        f"rather than selected between."
    )
    assert text is None, (
        f"refused, but not for the op — the splice landed wrong rather than "
        f"finding a divergence: {text}"
    )
