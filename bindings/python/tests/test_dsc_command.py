# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The `dsc` command an install puts on `PATH`, and what it runs.

Each test states which compilers exist by what it writes under `tmp_path`, so
none depends on whether this install's wheel carries one. `os.execv` is caught:
the command replaces its process, which would end the test.
"""

from __future__ import annotations

import os
import re
import stat
import subprocess
from importlib import metadata

import pytest

from pyds import _dsc_command


def _executable(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


@pytest.fixture
def run(tmp_path, monkeypatch):
    """Run the command as `tmp_path/venv/bin/dsc`; return what it would exec."""
    me = _executable(tmp_path / "venv" / "bin" / "dsc")
    monkeypatch.setattr(_dsc_command, "_BUNDLED", tmp_path / "pyds" / "bin" / "dsc")
    monkeypatch.setenv("PATH", str(me.parent))
    called = []

    def execv(binary, argv):
        called.append((binary, argv))

    monkeypatch.setattr(_dsc_command.os, "execv", execv)

    def go(*args):
        monkeypatch.setattr(_dsc_command.sys, "argv", [str(me), *args])
        _dsc_command.main()
        return called[-1]

    return go


def test_the_distribution_declares_the_command():
    points = metadata.entry_points(group="console_scripts", name="dsc")
    assert [p.value for p in points if p.dist.name == "ds-lang"] == ["pyds._dsc_command:main"]


def test_the_installed_command_runs():
    """The script the installer wrote, in its own process, with nothing else on `PATH`.

    A wheel with a compiler prints its version; one without says it has none.
    Either way the script imported its module and reached `main`.
    """
    files = metadata.distribution("ds-lang").files or []
    scripts = [
        f for f in files if f.name == "dsc" and f.parent.name == "bin" and "pyds" not in f.parts
    ]
    assert len(scripts) == 1, [str(f) for f in files if f.name == "dsc"]
    done = subprocess.run(
        [str(scripts[0].locate()), "--version"],
        env={**os.environ, "PATH": ""},
        capture_output=True,
        text=True,
        check=False,
    )
    assert re.match(r"dsc \d", done.stdout) or "carries no compiler" in done.stderr, done


def test_it_runs_the_bundled_compiler_by_its_own_path(run, tmp_path):
    """Its own path, because that is where the compiler finds its library."""
    bundled = _executable(tmp_path / "pyds" / "bin" / "dsc")
    assert run("compile", "a.ds", "-o", "a.dsc") == (
        str(bundled),
        [str(bundled), "compile", "a.ds", "-o", "a.dsc"],
    )


def test_the_bundled_compiler_wins_over_another_on_path(run, tmp_path, monkeypatch):
    bundled = _executable(tmp_path / "pyds" / "bin" / "dsc")
    other = _executable(tmp_path / "other" / "dsc")
    monkeypatch.setenv("PATH", f"{other.parent}:{tmp_path / 'venv' / 'bin'}")
    assert run("--version")[0] == str(bundled)


def test_with_none_bundled_it_skips_itself_and_runs_the_next_on_path(run, tmp_path, monkeypatch):
    other = _executable(tmp_path / "other" / "dsc")
    monkeypatch.setenv("PATH", f"{tmp_path / 'venv' / 'bin'}:{other.parent}")
    assert run("--version") == (str(other), [str(other), "--version"])


def test_with_no_compiler_it_says_so_and_does_not_run_itself(run):
    with pytest.raises(SystemExit, match="carries no compiler"):
        run("--version")
