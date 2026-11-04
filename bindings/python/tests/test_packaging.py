# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The installed distribution describes itself (PEP 440, 561, 621, 639).

The version is decided when pyds is built and kept in the distribution's
metadata; `pyds.__version__` reads it back rather than working one out at
import. The package carries its own type information, and its metadata says
what it is.
"""

from __future__ import annotations

import re
from importlib import metadata, resources
from pathlib import Path

import pyds

BINDING = Path(__file__).resolve().parents[1]
REPO_ROOT = BINDING.parents[1]

# The distribution's name, which is not the package's: pip installs
# `ds-lang`, and a program imports `pyds`.
DIST = "ds-lang"

# PEP 440's public version, with an optional local segment (the commit).
PEP440 = re.compile(
    r"^\d+(\.\d+)*((a|b|rc)\d+)?(\.post\d+)?(\.dev\d+)?(\+[a-z0-9]+(\.[a-z0-9]+)*)?$"
)


def test_version_is_the_distributions():
    assert pyds.__version__ == metadata.version(DIST)


def test_the_distribution_installs_the_package():
    # `ds-lang` is the distribution that owns `pyds/`.
    files = metadata.files(DIST) or []
    assert any(str(f).startswith("pyds/") for f in files), DIST


def test_version_is_pep_440_and_not_a_placeholder():
    v = metadata.version(DIST)
    assert PEP440.match(v), v
    assert not v.startswith("0.0.0"), v


def test_the_package_is_typed():
    assert resources.files("pyds").joinpath("py.typed").is_file()


def test_the_metadata_says_what_it_is():
    meta = metadata.metadata(DIST)
    assert meta["Name"] == DIST
    assert meta["Requires-Python"] == ">=3.12"
    assert meta["License-Expression"] == "BSD-4-Clause OR AGPL-3.0-or-later"
    assert "skeleton" not in (meta["Summary"] or "").lower()
    assert "Typing :: Typed" in (meta.get_all("Classifier") or [])


def test_the_licence_text_ships():
    dist = metadata.distribution(DIST)
    assert dist.metadata.get_all("License-File") == ["LICENSE"]
    text = dist.read_text("licenses/LICENSE")
    assert text is not None and "GNU AFFERO GENERAL PUBLIC LICENSE" in text


def test_the_licence_copy_is_the_repositorys():
    # PEP 639 takes no path outside the project, so the binding keeps a copy.
    # A copy is only a copy while it is byte-identical.
    assert (BINDING / "LICENSE").read_bytes() == (REPO_ROOT / "LICENSE").read_bytes()
