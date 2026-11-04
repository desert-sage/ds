# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""compile_file reads DS source as UTF-8 whatever the locale says.

DS source is UTF-8. `Path.read_text()` without an encoding uses the locale's,
so under an ASCII locale a non-ASCII source failed to read, and under another
8-bit one it would have read as mojibake. The child process runs with the C
locale and UTF-8 mode off, which is the ASCII case, and checks the text comes
through to the engine unchanged.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRATCH = Path(__file__).resolve().parents[3] / ".build" / "pyds-tests"

# The child compiles outside conftest's `use default`, and a source with no
# `use` line is a library dsc will not build ([LDIA.2.10.8]).
SOURCE = """\
use default

schema Trig scope logical:
    v: Int key

rule trig_logger:
    Trig
->
    log info "café ☕"
"""

CHILD = """\
import codecs, locale, sys
import pyds
# The premise: this process reads text as ASCII by default. If the image's
# Python decides otherwise, the test would pass without testing anything.
if codecs.lookup(locale.getencoding()).name != "ascii" or sys.flags.utf8_mode:
    print("premise failed:", locale.getencoding(), sys.flags.utf8_mode)
    sys.exit(2)
eng = pyds.Engine()
eng.load_dsc(pyds.compile_file(sys.argv[1]))
seen = []
eng.on_log = lambda ev: seen.append(ev.message)
eng.assert_("Trig", v=1)
eng.pump()
print(ascii(seen))
sys.exit(0 if "caf\\u00e9 \\u2615" in seen else 1)
"""


def test_a_utf8_source_compiles_under_an_ascii_locale():
    SCRATCH.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(dir=SCRATCH))
    try:
        src = work / "cafe.ds"
        src.write_bytes(SOURCE.encode("utf-8"))
        script = work / "child.py"
        script.write_text(CHILD, encoding="utf-8")
        env = {
            **os.environ,
            "LC_ALL": "C",
            "LANG": "C",
            "PYTHONUTF8": "0",
            "PYTHONCOERCECLOCALE": "0",
        }
        proc = subprocess.run(
            [sys.executable, str(script), str(src)],
            capture_output=True,
            text=True,
            timeout=300,
            env=env,
            encoding="utf-8",
        )
        assert proc.returncode == 0, (
            f"exit {proc.returncode}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    finally:
        for p in work.iterdir():
            p.unlink()
        work.rmdir()
