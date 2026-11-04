# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Tests for pyds.Engine.load_dsc (ICOM.18.W10)."""

from pathlib import Path

import pytest

import pyds

REPO_ROOT = Path(__file__).resolve().parents[3]
SAMPLES_DIR = REPO_ROOT / "bindings" / "python" / "tests" / "grammar_samples"


def _mvp_dsc_bytes() -> bytes:
    # Through pyds.compile, the path every integrator takes.
    text = (SAMPLES_DIR / "04_rule_minimal.ds").read_text()
    return pyds.compile(text, file="mvp.ds")


def test_engine_constructs():
    eng = pyds.Engine()
    assert eng is not None


def test_engine_load_dsc_succeeds_on_mvp():
    eng = pyds.Engine()
    eng.load_dsc(_mvp_dsc_bytes())


def test_engine_load_dsc_rejects_garbage():
    eng = pyds.Engine()
    with pytest.raises(pyds.LoadError):
        eng.load_dsc(b"this is not a .dsc file at all")


def test_engine_load_dsc_rejects_empty():
    eng = pyds.Engine()
    with pytest.raises(pyds.LoadError):
        eng.load_dsc(b"")


def test_load_error_is_exception_subclass():
    assert issubclass(pyds.LoadError, Exception)
