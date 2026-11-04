#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""scripts/formal/check_alloy.py [models-dir] — the `alloy` formal lane: solve the DS Alloy
consistency models (formal/alloy/*.als) headless in the ds-check image.

The thin recipe behind formal.build's `alloy.stamp` stamp step (Python port of
alloy-entrypoint.sh). Compile the RunAlloy harness from the mounted repo, then run
every model: `check` commands must be UNSAT (no counterexample), `run` commands
SAT. Non-zero if any command fails or the harness won't compile — a stamp
materializes only on exit 0.
"""
from __future__ import annotations

import glob
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))  # scripts/formal/ on path
import formal_arch  # noqa: E402


def main(argv: list[str]) -> int:
    # IDRISARM1 — amd64 only. FIRST, before the corpus is even looked at: a
    # refusal that reported "no *.als in formal/alloy" on an arm host would send
    # a reader after the wrong thing entirely.
    refused = formal_arch.refuse_off_amd64("alloy")
    if refused is not None:
        return refused

    d = Path(argv[1] if len(argv) > 1 else "formal/alloy")
    jar = os.environ.get("ALLOY_JAR", "/opt/alloy/alloy.jar")
    harness = d / "RunAlloy.java"
    if not harness.is_file():
        print(f"alloy: harness not found at {harness}", file=sys.stderr)
        return 2
    models = sorted(glob.glob(str(d / "*.als")))
    if not models:
        print(f"alloy: no .als models in {d}", file=sys.stderr)
        return 2
    with tempfile.TemporaryDirectory(prefix="ds-alloy.") as work:
        # -encoding UTF-8: RunAlloy.java has UTF-8 in comments; javac otherwise
        # defaults to the (locale-less container's) US-ASCII and fails to read it.
        subprocess.run(["javac", "-encoding", "UTF-8", "-cp", jar, "-d", work, str(harness)],
                       check=True)
        return subprocess.run(["java", "-cp", f"{jar}:{work}", "RunAlloy", *models]).returncode


if __name__ == "__main__":
    sys.exit(main(sys.argv))
