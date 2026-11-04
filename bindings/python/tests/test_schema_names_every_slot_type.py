# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A schema's slots name every slot type, Bytes included.

A type this pyds does not know is an error, never a placeholder: an "UNKNOWN"
is indistinguishable from corrupt data. A fact-ref (`Schema`) slot is covered
by the other compiled-schema tests.
"""

import pyds

_PROGRAM = """use default

schema S scope logical:
    i: Int mutable
    f: Float mutable
    s: String mutable
    b: Bool mutable
    j: Json mutable
    y: Bytes mutable
    t: Time mutable
    d: Date mutable
    u: Duration mutable
"""

TYPES = [
    ("i", pyds.SlotType.INT),
    ("f", pyds.SlotType.FLOAT),
    ("s", pyds.SlotType.STRING),
    ("b", pyds.SlotType.BOOL),
    ("j", pyds.SlotType.JSON),
    ("y", pyds.SlotType.BYTES),
    ("t", pyds.SlotType.TIME),
    ("d", pyds.SlotType.DATE),
    ("u", pyds.SlotType.DURATION),
]


def test_every_slot_type_is_named():
    eng = pyds.from_source(_PROGRAM)
    assert [(s.name, s.type) for s in eng.schemas["S"].slots] == TYPES
