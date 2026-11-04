# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""LSTR.8.5 through pyds: a String slot's text may cross as its UTF-8.

A ``str`` cannot carry octets that are not well-formed UTF-8 -- CPython refuses
to encode a lone surrogate -- so a String slot also takes ``bytes`` or
``bytearray`` as the text's UTF-8, which reaches libds's DS_ERR_ENCODING
refusal at assert ([LSTR.8.5]). The octets are handed to libds unchanged:
libds judges them, and its refusal is ``pyds.Error`` with ``Status.ENCODING``.
pyds decodes nothing, repairs nothing, and checks nothing but U+0000, which it
refuses before the call as it does in a ``str`` (LSTR.1.5).

``Cache.seed``'s ``value_json`` takes ``bytes`` too, and is held here.

The classes are libds's own test's (test_dsc_basic.c,
test_lstr_8_5__assert_and_seed_refuse_ill_formed_utf8): RFC 3629's five ways
for bytes to be no UTF-8, and well-formed text at the 2-, 3- and 4-byte lengths
and the last code point.
"""

from __future__ import annotations

import pytest

import pyds

_PROGRAM = """
schema Note scope ttl 1_min:
    text: String
    doc: Json
"""

_ILL = {
    "overlong": b"\xc0\xaf",
    "surrogate": b"\xed\xa0\x80",
    "past_10ffff": b"\xf4\x90\x80\x80",
    "cut_short": b"\xe2\x82",
    "stray_continuation": b"\x80",
}

_OK = [b"\xc3\xa9", b"\xe2\x82\xac", b"\xf0\x9f\x98\x80", b"\xf4\x8f\xbf\xbf"]

_BUFFERS = [bytes, bytearray]


def _engine() -> pyds.Engine:
    return pyds.from_source(_PROGRAM)


@pytest.mark.parametrize("make", _BUFFERS, ids=["bytes", "bytearray"])
@pytest.mark.parametrize("octets", list(_ILL.values()), ids=list(_ILL))
def test_lstr_8_5_string_octets_not_utf8_refused(octets, make):
    """The engine refuses them with Status.ENCODING, and nothing is asserted.

    Break: decode them in pyds, and the refusal is a UnicodeDecodeError that
    never reached the engine; pass them as anything but the String's text, and
    libds stores them.
    """
    eng = _engine()
    with pytest.raises(pyds.Error) as caught:
        eng.assert_("Note", text=make(octets), doc={})
    assert caught.value.status is pyds.Status.ENCODING
    assert len(eng.facts) == 0


@pytest.mark.parametrize("make", _BUFFERS, ids=["bytes", "bytearray"])
@pytest.mark.parametrize("octets", _OK, ids=["2", "3", "4", "10ffff"])
def test_lstr_8_5_string_octets_utf8_kept(octets, make):
    """The control: well-formed octets assert as the String they encode."""
    eng = _engine()
    eng.assert_("Note", text=make(octets), doc={})
    [fact] = eng.facts.of("Note")
    assert fact.slots["text"] == octets.decode("utf-8")


@pytest.mark.parametrize("make", _BUFFERS, ids=["bytes", "bytearray"])
def test_lstr_1_5_string_octets_nul_refused(make):
    r"""A 0x00 octet is U+0000, refused by pyds before the call, as in a str.

    Break: hand the octets to libds as they are, and it stores "a" for "a\0b".
    """
    eng = _engine()
    with pytest.raises(ValueError, match="embedded null character"):
        eng.assert_("Note", text=make(b"a\x00b"), doc={})
    assert len(eng.facts) == 0


def test_a_string_slot_refuses_what_is_neither_str_nor_bytes():
    """An int is still no String: TypeError, naming what the slot takes."""
    eng = _engine()
    with pytest.raises(TypeError, match="expected str or bytes"):
        eng.assert_("Note", text=7, doc={})
    assert len(eng.facts) == 0


@pytest.mark.parametrize("octets", list(_ILL.values()), ids=list(_ILL))
def test_lstr_8_5_seed_octets_not_utf8_refused(octets):
    """A seed's JSON text as bytes holding one is refused, and stores nothing.

    The cache holds one key, so the second seed is admitted only if the
    refused one left nothing behind.
    """
    eng = pyds.Engine()
    eng.cache.set_cap(keys=1)
    eng.load_dsc(pyds.compile(_PROGRAM, file="note.ds"))
    with pytest.raises(pyds.Error) as caught:
        eng.cache.seed("bad", b'"' + octets + b'"')
    assert caught.value.status is pyds.Status.ENCODING
    eng.cache.seed("good", b'"\xc3\xa9"')
