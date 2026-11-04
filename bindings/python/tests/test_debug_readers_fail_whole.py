# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""``engine.debug``'s network, match_trace and refracted fail whole.

Under an allocation failure each either raises MemoryError or returns the
complete answer; it never returns part of one. The sweep runs in a child
process (`_debug_readers_nomemory.py`), so a crash is a failure reported here.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

HELPER = Path(__file__).with_name("_debug_readers_nomemory.py")


def test_each_reader_raises_or_answers_whole():
    proc = subprocess.run(
        [sys.executable, str(HELPER)], capture_output=True, text=True, timeout=600
    )
    assert proc.returncode == 0, (
        f"exit {proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
    )
