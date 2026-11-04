# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""close() inside one of the engine's callbacks raises and changes nothing.

The cases run in a child process (`_close_in_callback.py`), so a crash is a
failure reported here.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HELPER = Path(__file__).with_name("_close_in_callback.py")


def test_close_inside_a_callback_is_refused():
    proc = subprocess.run(
        [sys.executable, str(HELPER)], capture_output=True, text=True, timeout=300
    )
    assert proc.returncode == 0, (
        f"exit {proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )
