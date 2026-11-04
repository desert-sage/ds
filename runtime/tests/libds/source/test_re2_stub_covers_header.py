# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The `regex`-declining stub defines every `ds_re2_*` the header declares.

`port/ds_re2_stub.c` is what a target that declines the `regex` dialect form
links instead of `ds_re2.cc` ([LREG.7.1] makes RE2 the language's regex). Of
the gates, only `msan`, a background one, links it (`-D re2=stub`), so this
compares the symbol sets: the stub defines every `ds_re2_*` that `ds_re2.h`
declares, and nothing else.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
HEADER = REPO / "runtime/src/libds/ds_re2.h"
STUB = REPO / "runtime/src/libds/port/ds_re2_stub.c"

# Comments are stripped before matching: both files name the other's symbols
# in prose.
_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"//[^\n]*")

# A declaration ends in `);`; a definition opens a brace. Both may wrap across
# lines, so the pattern spans newlines rather than matching line-wise.
_DECL = re.compile(r"\bds_re2_([a-z0-9_]+)\s*\([^;{]*\)\s*;", re.S)
_DEFN = re.compile(r"\bds_re2_([a-z0-9_]+)\s*\([^;{]*\)\s*\{", re.S)


def _strip(path: Path) -> str:
    return _LINE.sub(" ", _BLOCK.sub(" ", path.read_text()))


def _names(pattern: "re.Pattern[str]", path: Path) -> set[str]:
    return set(pattern.findall(_strip(path)))


def test_stub_defines_every_declared_re2_symbol():
    declared = _names(_DECL, HEADER)
    defined = _names(_DEFN, STUB)

    assert declared, "parsed no declarations out of ds_re2.h — the regex is wrong"

    missing = declared - defined
    assert not missing, (
        f"ds_re2.h declares {sorted('ds_re2_' + n for n in missing)} and "
        f"port/ds_re2_stub.c does not define them. Every target that declines "
        f"the `regex` dialect form will fail to link. Add a stub returning the "
        f"'no engine' answer."
    )


def test_stub_defines_nothing_the_header_does_not_declare():
    """A `ds_re2_*` defined in the stub but absent from the header is a symbol
    the real implementation dropped, or a typo; neither is a link error."""
    extra = _names(_DEFN, STUB) - _names(_DECL, HEADER)
    assert not extra, (
        f"port/ds_re2_stub.c defines {sorted('ds_re2_' + n for n in extra)}, "
        f"which ds_re2.h does not declare"
    )
