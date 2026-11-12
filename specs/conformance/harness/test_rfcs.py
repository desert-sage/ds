# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Unit tests for libds's fact-stream framing and recorder, as the harness
reads them (`pyds.atoms`, `Engine.record`).

The per-atom codec tests are `runtime/tests/libds/impl/test_rfcs_codec.c`.
"""

import os
import tempfile
from pathlib import Path

import pytest

import pyds
from pyds import AtomKind, atoms


def _record(eng, run) -> bytes:
    """What libds's recorder writes while `run(eng)` runs, on real disk."""
    scratch = os.environ["DS_MERCURY_SCRATCH"]
    Path(scratch).mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=scratch) as work:
        path = Path(work) / "test_rfcs.dstrace"
        with eng.record(path):
            run(eng)
        return path.read_bytes()


def test_frame_layout():
    # [RFCS.19.1]: outer 0x0A + varint len, then inner tag + varint len + body.
    # StreamHeader is field 258, so its inner key (258 << 3) | 2 = 2066 is two
    # bytes.
    a = atoms.frame(AtomKind.STREAM_HEADER, b"hello")
    assert a == bytes([0x0A, 0x08, 0x92, 0x10, 0x05]) + b"hello"


def test_frame_empty_body():
    # ClockAdvance is field 3: inner key 0x1A, one byte. Inner frame is key +
    # len = 2.
    assert atoms.frame(AtomKind.CLOCK_ADVANCE, b"") == bytes([0x0A, 0x02, 0x1A, 0x00])


def test_frame_refuses_a_four_letter_magic():
    with pytest.raises(TypeError):
        atoms.frame(b"FCST", b"x")


def test_rfcs_19_6__writer_refuses_unallocated_field():
    """[RFCS.19.6]: a writer must not frame at a field number the registry
    does not allocate. `pyds.atoms.frame` refuses before calling libds; libds's
    own refusal is test_rfcs_codec.c's test of this name. The number is chosen
    by the property under test, the first the registry does not allocate, so
    an allocation moves it rather than turning the test into a frame of a
    known atom.
    """
    unallocated = next(n for n in range(1, 1 << 29) if n not in AtomKind)
    with pytest.raises(ValueError):
        atoms.frame(unallocated, b"x")
    assert atoms.frame(AtomKind.CLOCK_ADVANCE, b"x"), "the control frames"


def test_iter_atoms_roundtrip():
    items = [(AtomKind.STREAM_HEADER, b"\x01\x02"),
             (AtomKind.FACT_ASSERT, b"body-bytes"),
             (AtomKind.CLOCK_ADVANCE, b""), (AtomKind.FACT_RETRACT, b"z")]
    stream = b"".join(atoms.frame(k, b) for k, b in items)
    assert [(a.kind, a.body) for a in atoms.iter_atoms(stream)] == items


def test_iter_atoms_truncated_prefix():
    # Cut inside the prefix: strict reading refuses, the lenient one ends.
    stream = atoms.frame(AtomKind.STREAM_HEADER, b"x")[:3]
    with pytest.raises(pyds.Error, match="truncated"):
        list(atoms.iter_atoms(stream))
    assert list(atoms.iter_atoms(stream, partial=True)) == []


def test_iter_atoms_truncated_body():
    # Declare a 10-byte body but supply only 3.
    stream = atoms.frame(AtomKind.FACT_ASSERT, b"x" * 10)[:-7]
    with pytest.raises(pyds.Error, match="truncated"):
        list(atoms.iter_atoms(stream))


def test_recorded_header_from_a_live_engine():
    # [RFCS.4.1] the StreamHeader first, and [LDET.1.10]: the DS version
    # libds's recorder stamps, non-empty.
    src = "use default\n\nschema Trig scope logical:\n    v: Int key\n"
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    stream = _record(eng, lambda e: e.assert_("Trig", v=1))
    first = next(atoms.iter_atoms(stream))
    assert first.kind is AtomKind.STREAM_HEADER
    header = first.message()
    assert header.ds_version == eng.session_header.ds_version != ""
    assert header.session_id == eng.session_header.session_id
    assert len(header.dsc_hash) == 32


def test_rfcs_7_5__fcrt_round_trip():
    """RFCS.7.5: a FactRetract carries the stream event's seq and clock_ns, read
    from what libds's recorder writes for a live retract, with both non-zero:
    proto3 omits a zero. libds's encode/decode round trip is test_rfcs_codec.c's
    test of this name.
    """
    src = "use default\n\nschema Pkt scope logical:\n    v: Int key\n"
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    def run(e):
        fact = e.assert_("Pkt", v=1)
        e.clock.advance(123_456)
        e.retract(fact)

    stream = _record(eng, run)
    recorded = list(atoms.iter_atoms(stream))
    asserted = [a.message() for a in recorded if a.kind is AtomKind.FACT_ASSERT]
    retracted = [a.message() for a in recorded if a.kind is AtomKind.FACT_RETRACT]
    assert len(asserted) == 1 and len(retracted) == 1
    (fa,), (fr,) = asserted, retracted
    assert fr.fact_id == fa.fact_id
    # Later than the assert's, so non-zero whatever the assert's is.
    assert fr.seq > fa.seq
    # The retract's clock sample: the advance itself records nothing
    # ([NTST.3.3]), and the retract samples the moved clock.
    assert fr.clock_ns == 123_456
