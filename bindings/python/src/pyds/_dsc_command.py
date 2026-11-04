# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The `dsc` command a `ds-lang` install puts on `PATH`.

The compiler itself stays at `pyds/bin/dsc`, because it finds its standard
library at `../share/ds/stdlib` from its own directory ([RCLI.1.11]), so a copy
or a link elsewhere would find none. This command replaces itself with that
binary.

A wheel with no compiler still installs this command, and `pyds.compile` falls
back to `dsc` on `PATH`, so a `dsc` further along `PATH` must be reachable
through it and this command must not find itself.
"""

from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

# Where `pyds/__init__.py:_BUNDLED_DSC` looks.
_BUNDLED = Path(__file__).resolve().parent / "bin" / "dsc"


def _other_dsc(script: str) -> str | None:
    """Find the first `dsc` on `PATH` that is not `script`, this command."""
    me = Path(script).resolve()
    for directory in os.get_exec_path():
        found = shutil.which("dsc", path=directory)
        if found is not None and Path(found).resolve() != me:
            return found
    return None


def main() -> None:
    """Run the bundled `dsc` with this process's arguments; it does not return."""
    binary = str(_BUNDLED) if _BUNDLED.is_file() else _other_dsc(sys.argv[0])
    if binary is None:
        sys.exit("dsc: this ds-lang carries no compiler, and there is no other dsc on PATH")
    os.execv(binary, [binary, *sys.argv[1:]])
