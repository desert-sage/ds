# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Frame an atom this runtime cannot emit, for [RFCS.16.3] and [LFST.10.3].

`pyds.atoms.frame` refuses a number its registry has no entry for, so this lays
the bytes out from [RFCS.19.1]'s grammar: the one place in the harness that
frames without the registry.
"""

from __future__ import annotations

from pyds import AtomKind
from pyds.atoms import Band, band

# A skip-band number ([RFCS.16.2]) no atom claims, which a reader must skip.
# Asserted ([RFCS.19.6]), since an allocation here would have these fixtures
# test a known atom.
UNKNOWN_SKIP_FIELD = 2000
assert UNKNOWN_SKIP_FIELD not in AtomKind, (
    f"field {UNKNOWN_SKIP_FIELD} has been allocated; the future-atom fixtures "
    f"need a number the registry does not know — pick another")
assert band(UNKNOWN_SKIP_FIELD) is Band.SKIP, (
    f"field {UNKNOWN_SKIP_FIELD} is not in the skip band")

# An inject-band number no atom claims, which a reader must refuse ([RFCS.16.3]).
UNKNOWN_INJECT_FIELD = 120
assert UNKNOWN_INJECT_FIELD not in AtomKind, (
    f"field {UNKNOWN_INJECT_FIELD} has been allocated; pick another")
assert band(UNKNOWN_INJECT_FIELD) is Band.INJECT, (
    f"field {UNKNOWN_INJECT_FIELD} is not in the inject band")


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def frame_future_atom(field: int, body: bytes = b"") -> bytes:
    """One framed atom for `field`, allocated or not ([RFCS.19.1])."""
    inner = _varint((field << 3) | 2) + _varint(len(body)) + body
    return b"\x0a" + _varint(len(inner)) + inner
