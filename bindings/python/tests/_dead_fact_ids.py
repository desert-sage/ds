# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""One misuse of a fact reference per run, for test_fact_ids.py.

Each case passes the engine a fact that is not live -- retracted, or never
asserted -- through one entry point. The engine must refuse it with KeyError.
Before the live-fact table, a fact reference was a pointer cast to an int and
each of these dereferenced it: a crash, or a read of freed memory. They run in
a child process, one case per run, so a crash is that case's exit status.

Exit 0 and print "KeyError" when the case is refused; otherwise print what
happened and exit 1.
"""

from __future__ import annotations

import sys

import pyds

# A source with no `use` line is a library, which dsc will not build
# ([LDIA.2.10.8]). The suite's conftest adds `use default` for in-process
# compiles; this runs as its own process, so it says so itself.
SOURCE = """\
use default

schema Motion scope logical:
    entity_id: String key
    state: Int mutable

schema Trace scope ttl 1_h:
    target: Motion
"""


def _engine() -> pyds.Engine:
    return pyds.from_source(SOURCE)


def retract_twice(eng: pyds.Engine) -> None:
    f = eng.assert_("Motion", entity_id="a", state=1)
    eng.retract(f)
    eng.retract(f)


def retract_invented(eng: pyds.Engine) -> None:
    eng.assert_("Motion", entity_id="a", state=1)
    eng.retract(140_000_000_000)


def inspect_retracted(eng: pyds.Engine) -> None:
    f = eng.assert_("Motion", entity_id="a", state=1)
    eng.retract(f)
    eng.facts[f]


def ref_to_retracted(eng: pyds.Engine) -> None:
    f = eng.assert_("Motion", entity_id="a", state=1)
    eng.retract(f)
    eng.assert_("Trace", target=f)


CASES = {
    f.__name__: f for f in (retract_twice, retract_invented, inspect_retracted, ref_to_retracted)
}


def main(case: str) -> int:
    try:
        CASES[case](_engine())
    except KeyError:
        print("KeyError")
        return 0
    except Exception as e:
        print(f"{case}: raised {type(e).__name__}: {e}")
        return 1
    print(f"{case}: accepted a fact that is not live")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
