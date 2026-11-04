# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`pyds.compile(dialect_files=...)` registers integrator dialects with `dsc`.

A program names its dialect in its `use` line ([LDIA.2.10.1]); a dialect the
language does not define is registered from a YAML file before anything is
compiled ([NDLC.2.1]), one `-d` per file, in order. `plain` is this suite's
own file (`default`'s settings under a name of its own); `restricted_v1` is the
harness's, which is what the conformance corpus registers this way.
"""

from pathlib import Path

import pytest

import pyds

_PLAIN = Path(__file__).resolve().parent / "dialects" / "plain.yaml"
_RESTRICTED_V1 = (
    Path(__file__).resolve().parents[3]
    / "specs"
    / "conformance"
    / "harness"
    / "dialects"
    / "restricted_v1.yaml"
)

_BODY = "schema S scope logical:\n    k: Int key\n"


def test_a_registered_dialect_compiles_and_loads():
    dsc = pyds.compile("use plain\n\n" + _BODY, file="s.ds", dialect_files=[_PLAIN])
    eng = pyds.Engine()
    eng.load_dsc(dsc)
    eng.assert_("S", k=1)
    assert len(eng.facts) == 1


def test_a_dialect_not_registered_is_refused():
    with pytest.raises(pyds.CompileRefusedError) as info:
        pyds.compile("use plain\n\n" + _BODY, file="s.ds")
    assert "DS_VALIDATE_UNKNOWN_DIALECT" in info.value.diagnostics


def test_every_file_given_is_registered():
    src = "use restricted_v1\n\n" + _BODY
    pyds.compile(src, file="r.ds", dialect_files=[_PLAIN, _RESTRICTED_V1])


def test_a_path_as_a_string_is_accepted():
    pyds.compile("use plain\n\n" + _BODY, file="s.ds", dialect_files=[str(_PLAIN)])


@pytest.mark.parametrize("one", [str(_PLAIN), _PLAIN])
def test_one_path_instead_of_a_sequence_is_refused(one):
    with pytest.raises(TypeError, match="sequence of paths"):
        pyds.compile("use plain\n\n" + _BODY, file="s.ds", dialect_files=one)


def test_dialect_files_is_keyword_only():
    with pytest.raises(TypeError, match="positional argument"):
        pyds.compile("use plain\n\n" + _BODY, "s.ds", None, None, None, [_PLAIN])


def test_compile_file_passes_dialect_files_on(tmp_path):
    src = tmp_path / "s.ds"
    src.write_text("use plain\n\n" + _BODY)
    pyds.Engine().load_dsc(pyds.compile_file(src, dialect_files=[_PLAIN]))
