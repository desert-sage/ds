# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
r"""A String slot value containing NUL is refused, not truncated.

libds takes a String slot as a NUL-terminated C string, so "a\0b" would be
stored as "a". Python refuses a NUL wherever a str becomes a C string, and so
does this.
"""

from __future__ import annotations

import pytest

import pyds

_PROGRAM = """use default

schema S scope logical:
    s: String key
"""


def _engine() -> pyds.Engine:
    return pyds.from_source(_PROGRAM)


@pytest.mark.parametrize("value", ["a\0b", "\0", "ab\0"])
def test_a_nul_is_refused(value):
    eng = _engine()
    with pytest.raises(ValueError):
        eng.assert_("S", s=value)
    assert len(eng.facts) == 0


def test_a_string_without_nul_is_stored_whole():
    eng = _engine()
    h = eng.assert_("S", s="aéb")
    assert eng.facts[h].slots["s"] == "aéb"
