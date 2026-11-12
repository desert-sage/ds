#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# @spec [RDSC.11.1] [RFCS.19.1] [RFCS.19.2]
"""Hypothesis property test: a `.dsc` frame whose declared length overruns the
artefact is refused as truncated ([RDSC.11.1]).

`load_dsc` is handed the complete artefact, so a declared length past its end is
the artefact being wrong, and [RDSC.11.1]'s framing rule names the code:
`DS_ERR_DSC_TRUNCATED`, at any position and whatever the length. An incremental
stream reader calls the same bytes EOF ([RFCS.19.2]); a loader must not.

Atom wire format ([RFCS.19.1]): `[0x0A][varint outer_len][Atom]`. Hypothesis
generates the overrun and shrinks any failure to a minimal one.

EVERY EDITED ARTEFACT IS RE-SEALED before it is loaded. The loader verifies the
header's `dsc_sha256` ([RDSC.3.6]) as it reads DscHeader, so an edit left
unsealed is refused for its hash, and the property would pass for a reason
that is not the overrun. The status is read off the refusal, never its text.
"""
from __future__ import annotations

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from dsc_seal import seal

# A minimal LOGICAL program; the loaded engine must accept a fact and count it.
PROGRAM_DS = "use default\n\nschema S scope logical:\n    k: Int key\n"

_DSC = None


def _dsc() -> bytes:
    global _DSC
    if _DSC is None:
        import pyds
        _DSC = pyds.compile(PROGRAM_DS, file="loader_overrun.ds")
    return _DSC


def _after_header(data: bytes) -> int:
    """The byte offset where the atom after the leading DscHeader starts,
    walked with libds's reader (`pyds.atoms`), since the prefix width varies
    with the field number and the body length."""
    from pyds import atoms
    offs = [a.offset for a in atoms.iter_atoms(data)]
    assert len(offs) >= 2, "the compiled artefact has no atom after its header"
    return offs[1]


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def test_the_unedited_artefact_loads():
    """The control: the artefact every property edits loads and runs, so a
    refusal below is the edit's."""
    import pyds

    eng = pyds.Engine()
    try:
        eng.load_dsc(seal(_dsc()))
        eng.clock.mode = "mock"
        eng.clock.set(0)
        eng.assert_("S", k=1)
        assert len(eng.facts) == 1
    finally:
        eng.close()


@settings(max_examples=100, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(claimed=st.integers(min_value=1, max_value=1 << 20))
def test_overrun_frame_is_truncated(claimed):
    """A frame whose declared length overruns the artefact is refused with
    DS_ERR_DSC_TRUNCATED ([RDSC.11.1]), never skipped to EOF."""
    import pyds

    base = _dsc()
    cut = _after_header(base)
    # An outer frame declaring more inner bytes than the whole artefact holds:
    # advancing by the declared length would run past EOF. Built by hand,
    # because the length has to disagree with what follows.
    overrun = b"\x0a" + _varint(len(base) + claimed)
    data = seal(base[:cut] + overrun + base[cut:])

    eng = pyds.Engine()
    try:
        with pytest.raises(pyds.Error) as exc:
            eng.load_dsc(data)
        assert getattr(exc.value, "status", None) == pyds.Status.DSC_TRUNCATED, (
            f"refused with {getattr(exc.value, 'status', None)!r}: {exc.value}")
    finally:
        eng.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
