# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A refused assert frees the Json trees it built for earlier slots.

Measured in a child process (`_refused_assert_rss.py`), so the suite's own
allocations do not blur the number.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HELPER = Path(__file__).with_name("_refused_assert_rss.py")


def test_refused_asserts_do_not_grow_the_process():
    proc = subprocess.run(
        [sys.executable, str(HELPER)], capture_output=True, text=True, timeout=600
    )
    assert proc.returncode == 0, (
        f"exit {proc.returncode}; resident growth (bytes): {proc.stdout.strip()}"
        f"\nstderr:\n{proc.stderr}"
    )
