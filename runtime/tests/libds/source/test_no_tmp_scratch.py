# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""No libds test writes under /tmp.

A build host's /tmp is a tmpfs shared with the CI runner and every other job
(BUILD-RUNBOOK.md §4: never /tmp, on any host). `spec_common.h`'s
`spec_load_ds` makes its scratch files under DS_MERCURY_SCRATCH, which
scripts/private/gate/gate.py makes on real disk for every gate that has the
compiler.

This holds the two suites libds-unit reads, `impl/` and `spec/`, headers
included: no string literal in them names /tmp. Comments are stripped first.
`alloc_conformance/` is read by its own background gate, so this scan does
not reach it.
"""
from __future__ import annotations

import re
from pathlib import Path

REPO = Path(__file__).resolve().parents[4]
SUITES = (REPO / "runtime/tests/libds/impl", REPO / "runtime/tests/libds/spec")

_BLOCK = re.compile(r"/\*.*?\*/", re.S)
_LINE = re.compile(r"//[^\n]*")
# A C string literal whose text names /tmp, as a path or a path's start.
_TMP_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*/tmp(?:/|")')


def _sources() -> list[Path]:
    return sorted(p for d in SUITES for p in (*d.glob("*.c"), *d.glob("*.h")))


def tmp_literals(text: str) -> list[str]:
    """The string literals in C source `text` that name /tmp, comments
    aside."""
    return _TMP_LITERAL.findall(_LINE.sub(" ", _BLOCK.sub(" ", text)))


def test_no_libds_test_names_tmp() -> None:
    bad = {str(p.relative_to(REPO)): found for p in _sources()
           if (found := tmp_literals(p.read_text(encoding="utf-8")))}
    assert not bad, (
        f"libds tests naming /tmp: {bad}. Make scratch files under "
        f"DS_MERCURY_SCRATCH (spec_common.h's spec_scratch_template), never "
        f"/tmp (BUILD-RUNBOOK.md §4)")


def test_the_scan_reads_both_suites() -> None:
    names = {p.parent.name for p in _sources()}
    assert names == {"impl", "spec"}, names
    assert any(p.name == "spec_common.h" for p in _sources())


def test_a_tmp_literal_is_found() -> None:
    assert tmp_literals('char p[] = "/tmp/spec_ds_XXXXXX";')
    assert tmp_literals('fopen("/tmp", "r");')
    assert tmp_literals('const char *d = "x" "/tmp/y";')


def test_a_mention_in_a_comment_or_a_longer_word_is_not() -> None:
    assert not tmp_literals("/* never under /tmp (BUILD-RUNBOOK.md) */")
    assert not tmp_literals("x = 1; // not /tmp/x\n")
    assert not tmp_literals('const char *d = "/tmpfs-free/x";')
    assert not tmp_literals('const char *d = "%s/spec_ds_XXXXXX";')
