# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The example harness, ``examples/harness.py``, runs every stage and ends ``harness: OK``.

The binding's gate runs it on every change, as every binding's example is run
by its own (``bindings/README.md``).
"""

import subprocess
import sys
from pathlib import Path

HARNESS = Path(__file__).resolve().parents[1] / "examples" / "harness.py"

STAGES = (
    "build",
    "compile",
    "make_engine",
    "register_callbacks",
    "setup_clock",
    "load",
    "size_engine",
    "assert_facts",
    "pump_and_answer",
    "read_facts",
    "introspect",
    "errors",
    "exchange",
    "record_and_replay",
    "clone",
    "time_passes",
    "teardown",
)


def test_the_example_harness_runs_every_stage_and_ends_ok(tmp_path):
    run = subprocess.run(
        [sys.executable, HARNESS], cwd=tmp_path, capture_output=True, text=True, encoding="utf-8"
    )
    assert run.returncode == 0, run.stdout + run.stderr
    headed = [
        line.removeprefix("== ").removesuffix(" ==")
        for line in run.stdout.splitlines()
        if line.startswith("== ")
    ]
    assert headed == list(STAGES)
    assert run.stdout.rstrip().endswith("harness: OK")
    # The program's rules reached the callbacks they exist for.
    for callback in (
        "[on_event]",
        "[on_log]",
        "[on_cache_set]",
        "[on_cache_delete]",
        "[call]",
    ):
        assert callback in run.stdout, callback
    # The zone's offset is a TimeZoneOffset fact, which the harness asserts.
    assert "assert zone ->" in run.stdout
