# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""How much a refused assert leaves behind, for test_refused_assert_leaks_nothing.py.

The schema puts a Json slot before an Int one, and every assert gives the Int
slot a str, so each is refused after the Json value has been built into a
libds tree. libds has no allocation counter, so this measures the process's
resident set across many such asserts, each carrying a 16 KB value: a leaked
tree per assert grows it by about 80 MB; none leaves it flat. The value stays
inside the Json limits (DS_JSON_MAX_STRING_BYTES is 16 KiB), or libds would
refuse the Json slot itself and the Int slot's refusal would never be reached.

Prints the growth in bytes. Exit 0 under LIMIT, else 1.
"""

from __future__ import annotations

import os
import subprocess
import sys

import pyds

N = 5_000
VALUE = {"x": "y" * 16_000}
LIMIT = 20 * 1024 * 1024


def _rss() -> int:
    if sys.platform.startswith("netbsd"):  # which mounts no /proc; ps says KiB
        ps = ["/bin/ps", "-o", "rss=", "-p", str(os.getpid())]
        return int(subprocess.run(ps, capture_output=True, text=True, check=True).stdout) * 1024
    with open("/proc/self/statm", encoding="ascii") as f:
        return int(f.read().split()[1]) * os.sysconf("SC_PAGE_SIZE")


def _refused(eng: pyds.Engine) -> None:
    try:
        eng.assert_("S", j=VALUE, n="not an int")
    except TypeError:
        return
    raise SystemExit("the assert was not refused, so this measures nothing")


_PROGRAM = """use default

schema S scope logical:
    j: Json key
    n: Int mutable
"""


def main() -> int:
    eng = pyds.from_source(_PROGRAM)
    for _ in range(200):  # warm the allocators before measuring
        _refused(eng)
    before = _rss()
    for _ in range(N):
        _refused(eng)
    growth = _rss() - before
    print(growth)
    return 0 if growth < LIMIT else 1


if __name__ == "__main__":
    sys.exit(main())
