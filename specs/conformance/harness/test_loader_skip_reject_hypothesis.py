#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# @spec [RDSC.9.2] [RDSC.9.3] [RDSC.9.4] [RFCS.16.1] [RFCS.16.2] [RFCS.16.3] [RFCS.19.1] [RFCS.19.2] [RFCS.19.8]
"""Hypothesis property test for the DSC loader skip/reject discipline ([RDSC.9.4]).

Forward-compatibility differential: a `.dsc` may carry atoms an older runtime
does not recognise. The loader reads atoms in stream order ([RDSC.9.3]); an atom
this reader has no entry for is skipped -- diagnose + advance past the declared
length and keep loading ([RDSC.9.4], skip-don't-reject) -- while a MALFORMED
frame (a declared length that overruns the buffer) must be rejected, never
skipped past.

An atom's identity is a protobuf field number ([RFCS.16.1]), so an unrecognised
atom is a number no registry entry claims, and the number alone decides the
disposition ([RFCS.16.2] / [RFCS.16.3]). These properties use the skip band.

The properties:
  * [RDSC.9.4] injecting any number of well-framed skip-band unknown atoms
    (after the mandatory leading DscHeader, [RDSC.9.2]) leaves the load outcome
    UNCHANGED: the DSC still loads and the engine behaves identically (the
    skipped bytes are invisible to execution).
  * a frame whose declared length overruns the remaining buffer is REJECTED
    (`load_dsc` raises), not silently skipped to EOF.

Atom wire format ([RFCS.19.1]): two nested length-delimited protobuf frames,
`[0x0A][varint outer_len][varint tag][varint body_len][body]`. Hypothesis
generates unallocated field numbers, bodies, and injection counts, and shrinks
any failure to a minimal artifact.

EVERY EDITED ARTEFACT IS RE-SEALED before it is loaded. The loader verifies the
header's `dsc_sha256` ([RDSC.3.6]) as it reads DscHeader, so an injected atom
left unsealed is refused for its hash: the skip property would fail, and the
overrun property would pass for a reason that is not the overrun. Sealing keeps
each property about what it names.
"""
from __future__ import annotations

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from dsc_seal import seal
from future_atom import frame_future_atom

# A minimal LOGICAL program; the loaded engine must accept a fact and count it.
PROGRAM_DS = "use default\n\nschema S scope logical:\n    k: Int key\n"

_DSC = None


def _dsc() -> bytes:
    global _DSC
    if _DSC is None:
        import pyds
        _DSC = pyds.compile(PROGRAM_DS, file="loader_skip.ds")
    return _DSC


def _boundaries(data: bytes) -> list[int]:
    """Byte offsets at which an atom starts, plus EOF -- the valid frame seams.

    Walked with libds's reader (`pyds.atoms`), since the prefix width varies
    with the field number and the body length.
    """
    from pyds import atoms
    offs = [a.offset for a in atoms.iter_atoms(data)]
    offs.append(len(data))
    return offs


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _unallocated_skip_field() -> st.SearchStrategy[int]:
    """Skip-band ([RFCS.16.2]: 256-2047) numbers no atom claims.

    Drawn from libds's own answer, so an allocation in the band narrows the
    strategy rather than turning these into tests of a known atom.
    """
    from pyds import AtomKind
    from pyds.atoms import Band, band
    fields = [f for f in range(2048)
              if band(f) is Band.SKIP and f not in AtomKind]
    assert fields, "libds puts no unallocated number in the skip band"
    return st.sampled_from(fields)


_BODY = st.binary(min_size=0, max_size=24)


@settings(max_examples=200, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(unknowns=st.lists(st.tuples(_unallocated_skip_field(), _BODY),
                         max_size=5))
def test_unknown_atoms_are_skipped(unknowns):
    """[RDSC.9.4] unknown skip-band atoms are skipped; the DSC still loads."""
    import pyds

    data = _dsc()
    # Inject each unknown atom right after the leading DscHeader ([RDSC.9.2]),
    # so the loader must skip mid-stream and still reach the real atoms that
    # follow.
    for field, body in unknowns:
        after_dsco = _boundaries(data)[1]
        data = data[:after_dsco] + frame_future_atom(field, body) + data[after_dsco:]

    eng = pyds.Engine()
    try:
        eng.load_dsc(seal(data))           # must NOT raise -- skip, don't reject
        eng.clock.mode = "mock"
        eng.clock.set(0)
        eng.assert_("S", k=1)
        assert len(eng.facts) == 1, "engine broken after skipping unknown atoms"
    finally:
        eng.close()


@settings(max_examples=100, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(field=_unallocated_skip_field(),
       claimed=st.integers(min_value=1, max_value=1 << 20))
def test_overrun_frame_is_rejected(field, claimed):
    """A frame whose declared length overruns the buffer is rejected.

    `load_dsc` is handed the complete artefact, so a declared length past its
    end is the artefact being wrong. An incremental reader calls the same bytes
    EOF ([RFCS.19.2], [RFCS.19.8]).
    """
    import pyds

    base = _dsc()
    after_dsco = _boundaries(base)[1]
    # An outer frame declaring more inner bytes than the whole artefact holds,
    # with none actually following: advancing by the declared length would run
    # past EOF. Built by hand, because the length has to disagree with the body.
    overrun = b"\x0a" + _varint(len(base) + claimed)
    data = seal(base[:after_dsco] + overrun + base[after_dsco:])

    eng = pyds.Engine()
    try:
        with pytest.raises(Exception) as exc:
            eng.load_dsc(data)
        # Sealed, so the hash is not what refused it ([RDSC.3.6]); without this
        # the property would pass on any refusal at all.
        assert "dsc_sha256" not in str(exc.value), (
            f"refused for the hash, not the overrun: {exc.value}")
    finally:
        eng.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
