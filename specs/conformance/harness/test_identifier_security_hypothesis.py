#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
# @spec [LNAM.2.2] [LNAM.2.2.2] [LNAM.2.3] [LNAM.2.3.1] [LNAM.2.4.1] [LNAM.2.5] [LNAM.2.5.1]
"""Hypothesis property test for identifier security ([LNAM.2.2] / [LNAM.2.3] /
[LNAM.2.5]).

The Trojan-source / homoglyph attack surface, exercised against the REAL
compiler over its pinned Unicode 16.0 tables -- exactly what a solver/model can't
reach and property-based generation can. The compiler validates identifiers at
lex time ([LNAM.2.4.1]); an illegal name makes `pyds.compile` raise.

Properties:
  * [LNAM.2.2.2] every legacy ASCII identifier is legal (the control).
  * [LNAM.2.5.1] a mixed-script identifier (Latin + a Cyrillic homoglyph, e.g.
    `pаypal`) MUST be rejected -- Highly Restrictive; admitting one is a
    security hole.
  * [LNAM.2.2.2] an identifier containing ZWJ (U+200D) or ZWNJ (U+200C) -- the
    invisible-joiner confusability hazard -- MUST be rejected.
  * [LNAM.2.3.1] / [LNAM.2.4.1] a name and its NFC/NFD-equivalent denote the SAME
    identifier, so declaring both is a duplicate.
"""
from __future__ import annotations

import pytest
from hypothesis import assume, given, settings, HealthCheck
from hypothesis import strategies as st

# Latin letters that have a Cyrillic look-alike (homoglyph) -- the confusable pairs.
_HOMOGLYPH = {"a": "а", "e": "е", "o": "о", "p": "р", "c": "с", "x": "х", "y": "у"}


def _refusal_types() -> tuple[type[BaseException], ...]:
    """What a refusal looks like from `pyds.compile`. A missing binary raises
    RuntimeError, which must not read as a refused identifier."""
    import pyds
    return (pyds.CompileRefusedError,)


def _compiles(source: str) -> bool:
    import pyds
    try:
        pyds.compile(source, file="idsec.ds")
        return True
    except _refusal_types():
        return False


def _decl(name: str) -> str:
    return f"schema {name} scope logical:\n    k: Int key\n"


def _schema(name: str) -> str:
    # A program, so the refusal under test is the identifier's: a source with
    # no `use` line is a library, refused by `dsc` whatever its names are.
    return "use default\n\n" + _decl(name)


# Uppercase-Latin-prefixed names over the homoglyph letters: always single-script
# Latin (legal, and never a keyword, since no keyword matches "T[aeopcxy]*").
_BODY = st.text(alphabet="aeopcxy", min_size=1, max_size=8)


@settings(max_examples=200, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(body=_BODY, pos=st.integers(min_value=0, max_value=7))
def test_mixed_script_rejected(body, pos):
    """[LNAM.2.2.2] pure-Latin is legal; [LNAM.2.5.1] one Cyrillic homoglyph makes
    it mixed-script -> rejected."""
    latin = "T" + body
    assert _compiles(_schema(latin)), f"pure-Latin identifier {latin!r} rejected"

    j = pos % len(body)
    mixed = "T" + body[:j] + _HOMOGLYPH[body[j]] + body[j + 1:]
    assert not _compiles(_schema(mixed)), (
        f"mixed-script identifier {mixed!r} (Latin + Cyrillic) was ADMITTED "
        f"-- [LNAM.2.5.1] Highly-Restrictive violation")


@settings(max_examples=100, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(body=_BODY, pos=st.integers(min_value=1, max_value=8),
       joiner=st.sampled_from(["‍", "‌"]))
def test_zero_width_joiner_rejected(body, pos, joiner):
    """[LNAM.2.2.2] ZWJ / ZWNJ must not appear in an identifier."""
    name = "T" + body
    j = pos % (len(name) + 1)
    injected = name[:j] + joiner + name[j:]
    assume(injected != name)
    assert not _compiles(_schema(injected)), (
        f"identifier with ZWJ/ZWNJ {injected!r} was admitted -- [LNAM.2.2.2]")


# Latin letters with a single-codepoint NFC form and a two-codepoint NFD form.
_ACCENT = st.sampled_from([
    ("é", "é"),   # é  vs  e + COMBINING ACUTE
    ("á", "á"),   # á  vs  a + COMBINING ACUTE
    ("ö", "ö"),   # ö  vs  o + COMBINING DIAERESIS
    ("ü", "ü"),   # ü  vs  u + COMBINING DIAERESIS
    ("ñ", "ñ"),   # ñ  vs  n + COMBINING TILDE
])


@settings(max_examples=50, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
@given(accent=_ACCENT)
def test_nfc_identity_is_a_duplicate(accent):
    """[LNAM.2.3.1] / [LNAM.2.4.1] the NFC and NFD spellings are the SAME name;
    declaring a schema under each is a duplicate (rejected)."""
    nfc, nfd = accent
    name_nfc = "Caf" + nfc
    name_nfd = "Caf" + nfd
    # Each spelling on its own is a legal single-script Latin identifier.
    assert _compiles(_schema(name_nfc)), f"NFC name {name_nfc!r} rejected"
    assert _compiles(_schema(name_nfd)), f"NFD name {name_nfd!r} rejected"
    # Both together are the same normalized name -> duplicate schema -> reject.
    # ONE `use` line: a second is DS_PARSE_DUPLICATE_USE, which would refuse
    # this for a reason that is not the one under test.
    both = _schema(name_nfd) + _decl(name_nfc).replace("k:", "j:")
    assert not _compiles(both), (
        f"NFD+NFC of the same name {name_nfc!r} were treated as distinct "
        f"-- [LNAM.2.3.1] normalization identity broken")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
