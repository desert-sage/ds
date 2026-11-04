# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Where the suite writes.

- pytest's `tmp_path` is under the clone. The project writes nothing to
  /tmp, on any host or in any container; the pyds gate passes `--basetemp`,
  and this fails if it stops.
"""

from __future__ import annotations

from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]


def test_tmp_path_is_inside_the_clone(tmp_path):
    assert tmp_path.resolve().is_relative_to(REPO_ROOT), (
        f"tmp_path is {tmp_path}, outside the clone at {REPO_ROOT}: "
        f"the gate's --basetemp is missing"
    )
