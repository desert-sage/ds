# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Every `test_*.py` in this directory is named by a gate in `scripts/private/gate/gate.py`.

This directory is gated per file, not as a directory: `conformance` names its
files in `_CONFORMANCE_FILES`, `hypothesis` names its own in
`_HYPOTHESIS_FILES`, and nothing else names a file here (`coverage`'s "all
tests" figure runs `_CONFORMANCE_FILES` too). So a new `test_*.py`
dropped beside these is run by nothing and reports nothing, while
`conformance.stamp`'s `reads` glob still puts it in the key. This test is that
file's red. It is named in `_CONFORMANCE_FILES` itself, and `conformance` is
selected by every path in this directory, so adding a file here always runs
it.

The names are read from `scripts/private/gate/gate.py`'s text, not imported: importing the gate
module would run its setup in the harness's process.
"""
from __future__ import annotations

import re
from pathlib import Path

_HARNESS = Path(__file__).resolve().parent
_GATE_PY = _HARNESS.parents[2] / "scripts" / "private" / "gate" / "gate.py"
_NAMED = re.compile(r'"specs/conformance/harness/(test_[A-Za-z0-9_]+\.py)"')


def named_in(gate_text: str) -> set[str]:
    """The harness test files a gate module's text names, as quoted paths."""
    return set(_NAMED.findall(gate_text))


def unnamed(present: set[str], gate_text: str) -> set[str]:
    """The test files present that no quoted path in `gate_text` names."""
    return present - named_in(gate_text)


def test_every_harness_test_file_is_run_by_a_gate() -> None:
    present = {p.name for p in _HARNESS.glob("test_*.py")}
    missing = unnamed(present, _GATE_PY.read_text(encoding="utf-8"))
    assert not missing, (
        f"{sorted(missing)} run under no gate. Name each in scripts/private/gate/gate.py: "
        "`_CONFORMANCE_FILES` for a check `conformance` should make, "
        "`_HYPOTHESIS_FILES` for a property test.")


def test_the_scan_sees_the_gate_lists() -> None:
    # The two lists the scan must reach, so a reworded gate module that the
    # pattern no longer matches fails here rather than reading as "all named".
    named = named_in(_GATE_PY.read_text(encoding="utf-8"))
    assert {"test_conformance.py", "test_runner_codes.py",
            "test_harness_files_gated.py"} <= named
    assert any(n.endswith("_hypothesis.py") for n in named)


def test_an_unnamed_file_is_reported() -> None:
    text = '"specs/conformance/harness/test_a.py",\n'
    assert unnamed({"test_a.py", "test_b.py"}, text) == {"test_b.py"}


def test_a_bare_mention_is_not_a_name() -> None:
    # A comment or a path in another directory does not run the file.
    text = ("# test_b.py is slow\n"
            '"specs/conformance/other/test_b.py",\n'
            '"specs/conformance/harness/test_b.pyc",\n')
    assert unnamed({"test_b.py"}, text) == {"test_b.py"}
