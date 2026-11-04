# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Which `dsc` `pyds.compile()` runs: `DS_MERCURY_DSC`, the bundled one, `PATH`.

The wheel half of shipping the compiler: an installed pyds
wheel carries `pyds/bin/dsc`, built with the libds it links. The bundled one
comes before `PATH` because a `dsc` from another release would emit artefacts
this package's loader refuses ([LDET.1.10]); an explicit `DS_MERCURY_DSC` comes
first because it is a choice someone made.

The bundled path is pointed at a file under `tmp_path` rather than the
package's, which in a source checkout does not exist -- each test states which
of the three it is about by what exists, not by what the tree happens to hold.
"""

import pytest

import pyds


@pytest.fixture
def bundled(tmp_path, monkeypatch):
    path = tmp_path / "bin" / "dsc"
    path.parent.mkdir()
    monkeypatch.setattr(pyds, "_BUNDLED_DSC", path)
    return path


def test_the_environment_wins_over_the_bundled_compiler(bundled, monkeypatch):
    bundled.write_bytes(b"")
    monkeypatch.setenv("DS_MERCURY_DSC", "/chosen/dsc")
    assert pyds._dsc() == "/chosen/dsc"


def test_the_bundled_compiler_wins_over_path(bundled, monkeypatch):
    bundled.write_bytes(b"")
    monkeypatch.delenv("DS_MERCURY_DSC", raising=False)
    assert pyds._dsc() == str(bundled)


def test_with_neither_it_is_dsc_on_path(bundled, monkeypatch):
    monkeypatch.delenv("DS_MERCURY_DSC", raising=False)
    assert not bundled.exists()
    assert pyds._dsc() == "dsc"


def test_an_empty_environment_variable_does_not_count(bundled, monkeypatch):
    """`DS_MERCURY_DSC=` names no binary; it must not hide the bundled one."""
    bundled.write_bytes(b"")
    monkeypatch.setenv("DS_MERCURY_DSC", "")
    assert pyds._dsc() == str(bundled)


def test_compile_runs_the_bundled_compiler(bundled, monkeypatch):
    """Not just the lookup: the binary `compile()` invokes is the bundled one.

    An empty file is not executable, so the failure names it.
    """
    bundled.write_bytes(b"")
    monkeypatch.delenv("DS_MERCURY_DSC", raising=False)
    with pytest.raises((RuntimeError, PermissionError, OSError)) as info:
        pyds.compile("schema S scope logical:\n    k: Int key\n")
    assert str(bundled) in str(info.value)
