# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Refraction is not observably erased by an unrelated mutation.

Refraction is a suppression that PERSISTS UNTIL THE MATCH BREAKS. The
generation counter below reads as though an unrelated mutation erased it; this
file shows by measurement that it does not, kept as a test so the answer stays
true.

The mechanism:

  * `rete/terminal.c` `refract_lookup()` treats an entry whose `generation`
    differs from the current one as ABSENT.
  * `rete/wm_rete.c` bumps `engine->cycle_generation` on EVERY assert and EVERY
    retract, citing [IRET.11.3.2] — which states exactly that as the definition:
    "The refraction set is cleared when a new fact is asserted or retracted".
  * so a refraction entry recorded by a firing is stale the moment anything is
    asserted, including by that firing's own RHS.

But the entry being stale is not observable, because nothing consults it. The
agenda is a POP loop (`rete/engine.c`): an activation is considered once and is
never re-pushed unless its token is REBUILT, and a token is rebuilt only when
one of its own facts changes — in which case re-firing is correct, the match
having changed.
So the only re-activation that refraction could suppress is one arriving with no
intervening mutation, and the one path that produces it, clock-tick re-eval, is
handled by [LTIM.2.5.1]'s separate one-shot, whose own source comment says it
"persists across cycle-generations, unlike the refraction table".

The measured consequence, therefore, is that the refraction table is close to
INERT, and the generation-counter behaviour is not author-visible when an
unrelated fact is asserted between pumps.

`alert` is the observable: one string per firing, and unlike `fact_count` it
sees a re-firing whose RHS is idempotent.
"""

from log_sink import capture_critical

import pyds

_PROBE = """
schema Trig scope logical:
    v: Int key
    x: Int mutable

schema Poke scope logical:
    n: Int key

rule r_watch:
    Trig
->
    log critical "watch"

rule r_poke:
    Poke
->
    log critical "poke"
"""


def _run(steps):
    """Apply `steps` and return the alerts, in order."""
    try:
        eng = pyds.from_source(_PROBE)
    except Exception as exc:  # surface the diagnostic, do not guess
        detail = getattr(exc, "errors", None)
        raise AssertionError(
            f"probe program did not compile: {exc}\n" + "\n".join(str(e) for e in (detail or []))
        ) from exc
    alerts: list[str] = []
    capture_critical(eng, alerts)
    for step in steps:
        if step[0] == "assert":
            eng.assert_(step[1], **step[2])
        elif step[0] == "pump":
            eng.pump()
        else:
            raise ValueError(f"unknown step {step[0]!r}")
    return alerts


def test_control_single_assert_and_pump():
    """The control: one assert and one pump fire `watch` exactly once.

    If this is not exactly one `watch` the probe is broken and nothing else in
    this file means anything.
    """
    assert _run([("assert", "Trig", {"v": 1, "x": 1}), ("pump",)]) == ["watch"]


def test_second_pump_with_no_mutation_does_not_refire():
    """A second pump with no assert or retract between does not re-fire.

    There is no generation bump. The activation was popped in pump 1 and is
    not re-pushed.
    """
    alerts = _run(
        [
            ("assert", "Trig", {"v": 1, "x": 1}),
            ("pump",),
            ("pump",),
        ]
    )
    assert alerts == ["watch"], f"expected one firing, got {alerts!r}"


def test_unrelated_assert_between_pumps_does_not_refire():
    """THE CASE the generation counter puts in doubt.

    `r_watch` fires in pump 1 and records refraction at generation G. Asserting
    an unrelated `Poke` bumps the generation, so that entry is stale when pump 2
    runs — and `r_watch`'s match has NOT broken. It must stay suppressed, and
    it does: `watch` fires once, not twice. The staleness is
    real and unreachable.
    """
    alerts = _run(
        [
            ("assert", "Trig", {"v": 1, "x": 1}),
            ("pump",),
            ("assert", "Poke", {"n": 1}),
            ("pump",),
        ]
    )
    assert alerts == ["watch", "poke"], (
        f"expected r_watch to fire once and r_poke once, got {alerts!r}"
    )


def test_upsert_of_the_matched_fact_refires():
    """The contrast: an upsert of the matched fact does re-fire.

    So the test above cannot be read as "nothing ever re-fires". Updating a
    non-key slot of the matched fact rebuilds its token, which IS the match
    changing, so the second firing is correct.
    """
    alerts = _run(
        [
            ("assert", "Trig", {"v": 1, "x": 1}),
            ("pump",),
            ("assert", "Trig", {"v": 1, "x": 2}),
            ("pump",),
        ]
    )
    assert alerts == ["watch", "watch"], f"expected a firing per distinct match, got {alerts!r}"
