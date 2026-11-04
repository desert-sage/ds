# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""close() from inside one of the engine's own callbacks.

libds refuses to free an engine that is inside its own callback
([RARC.13.16]). pyds must refuse with it: raise from close(), and leave the
engine, its callbacks and any recording exactly as they were. Before the fix
pyds discarded the refusal, dropped its pointer to the still-running engine
(leaking it) and closed the recording under the recorder, which stays
installed.

Run as a script by test_close_in_callback.py, in its own process, because the
recording case reached a zeroed recorder. Exit 0 when both cases hold.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

import pyds

SCRATCH = Path(__file__).resolve().parents[3] / ".build" / "pyds-tests"


_PROGRAM = """use default

schema S scope logical:
    k: Int key
"""


def _engine() -> pyds.Engine:
    return pyds.from_source(_PROGRAM)


def _close_from_the_stream(eng: pyds.Engine) -> list[BaseException | None]:
    seen: list[BaseException | None] = []

    def on_event(ev: pyds.events.Event) -> None:
        if seen:
            return
        try:
            eng.close()
        except Exception as e:
            seen.append(e)
        else:
            seen.append(None)

    eng.on_event = on_event
    eng.assert_("S", k=1)
    eng.pump()
    return seen


def case_plain() -> str | None:
    eng = _engine()
    seen = _close_from_the_stream(eng)
    if seen != [] and seen[0] is None:
        return "close() returned inside a callback instead of raising"
    if not seen:
        return "the stream callback never ran"
    if len(eng.facts) != 1:
        return f"the engine changed: len(facts) is {len(eng.facts)}"
    eng.close()
    return None


def case_recording() -> str | None:
    SCRATCH.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(dir=SCRATCH))
    path = work / "run.dstrace"
    eng = _engine()
    recording = eng.record(path)
    seen = _close_from_the_stream(eng)
    if seen and seen[0] is None:
        return "close() returned inside a callback while recording"
    eng.assert_("S", k=2)
    eng.pump()
    recording.close()
    size = path.stat().st_size
    eng.close()
    path.unlink()
    work.rmdir()
    if size == 0:
        return "the recording is empty"
    return None


def main() -> int:
    for case in (case_plain, case_recording):
        finding = case()
        if finding is not None:
            print(f"{case.__name__}: {finding}")
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
