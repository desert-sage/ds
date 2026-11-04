#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Print the version pyds is built as; meson's `project()` reads it.

`DS_BUILD_VERSION` when the build names one -- a release builds the release
version, the clean form the wheel's filename carries. Otherwise the provenance
form of `scripts/build/ds-version.py`, `<VERSION>+<sha>`, which PEP 440 reads
as a local version: a build from a checkout says which commit it is.

The installed distribution's metadata is the only place the version is kept;
`pyds.__version__` reads it back through `importlib.metadata`.
"""

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    """Print the version, as the module docstring says; return the exit status."""
    named = os.environ.get("DS_BUILD_VERSION", "").strip()
    if named:
        print(named)
        return 0
    out = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "build" / "ds-version.py"), str(ROOT)],
        stdout=subprocess.PIPE,
        text=True,
        check=True,
    ).stdout.strip()
    if not out:
        print(f"version.py: no VERSION file under {ROOT}", file=sys.stderr)
        return 1
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
