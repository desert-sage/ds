# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Run each debug reader with one Python allocation failing at a time.

Run as a script by test_debug_readers_fail_whole.py, in its own process,
because the defect it looks for includes a NULL dereference: a crash here is
the child's exit status, not the end of the suite.

For every allocation the reader makes, a run where exactly that one fails must
either raise MemoryError or return the whole answer. A shorter answer, a
SystemError (a result returned with an exception set), or a crash is the
defect. Exit 0 when every reader holds; otherwise the first finding is printed
and the exit status is non-zero.
"""

from __future__ import annotations

import _testcapi
import sys

import pyds

# A source with no `use` line is a library, which dsc will not build
# ([LDIA.2.10.8]); this runs as its own process, outside conftest's
# `use default`, so it says so itself.
SOURCE = """\
use default

schema Trig scope logical:
    v: Int key

rule trig_logger:
    Trig
->
    log info "trig fired"
"""

# Comfortably more allocations than any one reader makes on this network. The
# sweep checks it reached past the end: the last runs must succeed untouched.
SWEEP = 3000


def main() -> int:
    eng = pyds.from_source(SOURCE)
    fid = eng.assert_("Trig", v=1)
    eng.pump()

    readers = {
        "network": lambda: eng.debug.network(),
        "match_trace": lambda: eng.debug.match_trace(fid),
        "refracted": lambda: eng.debug.refracted(),
    }
    for name, read in readers.items():
        whole = read()
        empty = (not whole.nodes or not whole.edges) if name == "network" else not whole
        if empty:
            print(
                f"{name}: the untouched answer is empty, so the sweep would "
                f"measure nothing: {whole!r}"
            )
            return 2
        refused = 0
        last_ok = -1
        for n in range(SWEEP):
            _testcapi.set_nomemory(n, n + 1)
            try:
                got = read()
            except MemoryError:
                got = None
            finally:
                _testcapi.remove_mem_hooks()
            if got is None:
                refused += 1
                continue
            if got != whole:
                print(
                    f"{name}: allocation {n} failed and the reader returned "
                    f"a different answer instead of raising: {got!r}"
                )
                return 1
            last_ok = n
        if refused == 0:
            print(f"{name}: no injected failure reached the reader")
            return 3
        if last_ok != SWEEP - 1:
            print(f"{name}: the sweep did not reach past the reader's last allocation; raise SWEEP")
            return 4
        print(f"{name}: {refused} injected failures, each raised MemoryError")
    return 0


if __name__ == "__main__":
    sys.exit(main())
