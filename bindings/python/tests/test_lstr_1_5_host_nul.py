# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""LSTR.1.5's host arm: a host value carrying U+0000 is refused where it enters.

A String holds no U+0000 (LSTR.1.1), so a host value that would carry one is
refused, never cut short.

pyds refuses with the ValueError Python gives an embedded NUL, before libds
is called:
- a String slot, since libds takes a C string that the NUL would end;
- a Json string or object key. libds's builder refuses one too, but with a
  status (DS_ERR_INVAL), and a NUL in a str is the caller's value, not a
  libds failure.

These are the workorder's runtime/LSTR.1.5_host_string_nul_refused and
runtime/LSTR.1.5_host_json_nul_refused. The conformance harness has no way to
expect a refused assert, so they live here.
"""

import pytest

import pyds

_PROGRAM = """
schema Note scope ttl 1_min:
    text: String
    doc: Json
"""


def _engine():
    return pyds.from_source(_PROGRAM)


def test_lstr_1_5_host_string_nul_refused():
    r"""Break: pass the string through, and libds stores "a" for "a\0b"."""
    eng = _engine()
    with pytest.raises(ValueError, match="embedded null character"):
        eng.assert_("Note", text="a\x00b", doc={})
    assert len(eng.facts) == 0


@pytest.mark.parametrize(
    "doc",
    [
        "a\x00b",  # a Json string
        {"k": "a\x00b"},  # a nested leaf
        ["x", "a\x00b"],  # an array item
        {"a\x00b": 1},  # an object key
    ],
    ids=["string", "leaf", "item", "key"],
)
def test_lstr_1_5_host_json_nul_refused(doc):
    """Break: drop pyds's check, and libds's INVAL comes back as pyds.Error."""
    eng = _engine()
    with pytest.raises(ValueError, match="embedded null character"):
        eng.assert_("Note", text="ok", doc=doc)
    assert len(eng.facts) == 0


def test_a_string_without_nul_is_kept_whole():
    """The control: the same values with no NUL assert, and read back whole."""
    eng = _engine()
    eng.assert_("Note", text="ab", doc={"k": "ab"})
    [fact] = eng.facts.of("Note")
    assert fact.slots["text"] == "ab"
