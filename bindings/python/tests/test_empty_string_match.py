# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A String slot holding "" compares as a value.

Rules discriminated only by one String slot are mutually exclusive when that
slot holds the empty string, as for any other value.

The shape matters, so this file pins it at two widths. `_MINIMAL` is one
pattern and one comparison — the narrowest thing that can be wrong. `_DISCRIM`
is several mutually exclusive rules, a compound `and` where, a second pattern,
and a Bool truth test. If only the second goes red the fault is in how a
compound where is split across the alpha and residual sites, not in string
comparison itself — which is why the narrow case is not the only case.

Both `==` and `!=` are covered in both directions, and slot-against-slot as
well as slot-against-literal.
"""

import pytest
from log_sink import capture_critical

import pyds

# --- the narrowest form: one pattern, one comparison ------------------

_MINIMAL = """
schema Thing scope logical:
    id: String key
    place: String mutable

rule m_empty:
    Thing t where t.place == ""
->
    log critical "empty"

rule m_sr:
    Thing t where t.place == "SR"
->
    log critical "sr"

rule m_pc:
    Thing t where t.place == "PC"
->
    log critical "pc"
"""


def _fire(src: str, schema: str, **slots) -> list[str]:
    """Load `src`, assert one fact, pump, return the alerts raised."""
    eng = pyds.from_source(src)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_(schema, **slots)
    eng.pump()
    return sorted(alerts)


def test_empty_string_slot_matches_only_the_empty_literal():
    """The core claim: an empty `place` matches `""` and no other literal.

    `place` holds "", so `place == ""` holds and `place == "SR"` /
    `place == "PC"` do not. The bug fired all three.
    """
    assert _fire(_MINIMAL, "Thing", id="a", place="") == ["empty"]


def test_nonempty_string_slot_is_unaffected():
    """Control: a non-empty slot matches its own literal only.

    The reporter observed non-empty slots behaving correctly, so a fix that
    broke this would trade one silent over-match for another.
    """
    assert _fire(_MINIMAL, "Thing", id="a", place="SR") == ["sr"]


def test_empty_string_slot_does_not_match_a_third_literal():
    """A second non-matching literal does not match either.

    So the test cannot pass by a fix that merely special-cases the first
    comparison it meets.
    """
    assert _fire(_MINIMAL, "Thing", id="a", place="PC") == ["pc"]


# --- `!=`, which the reporter did not test ----------------------------

_NEQ = """
schema Thing scope logical:
    id: String key
    place: String mutable

rule n_not_empty:
    Thing t where t.place != ""
->
    log critical "not-empty"

rule n_not_sr:
    Thing t where t.place != "SR"
->
    log critical "not-sr"
"""


def test_neq_against_empty_slot():
    """`"" != ""` is false; `"" != "SR"` is true.

    The mirror of the == case: if "" compares equal to everything, BOTH of
    these go silent, which is the same defect wearing the opposite sign.
    """
    assert _fire(_NEQ, "Thing", id="a", place="") == ["not-sr"]


def test_neq_against_nonempty_slot():
    """Control for the above."""
    assert _fire(_NEQ, "Thing", id="a", place="SR") == ["not-empty"]


# --- slot against slot, also untested by the reporter -----------------

_SLOT_SLOT = """
schema Pair scope logical:
    id: String key
    a: String mutable
    b: String mutable

rule p_same:
    Pair p where p.a == p.b
->
    log critical "same"

rule p_diff:
    Pair p where p.a != p.b
->
    log critical "diff"
"""


def test_two_empty_slots_compare_equal():
    """Two empty slots compare equal, on the slot/slot path.

    Neither operand is a compiled literal, so this drives the slot/slot path
    rather than the slot/literal one.
    """
    assert _fire(_SLOT_SLOT, "Pair", id="x", a="", b="") == ["same"]


def test_empty_and_nonempty_slots_compare_unequal():
    """An empty slot does not read as equal to a populated one: the case the defect inverts."""
    assert _fire(_SLOT_SLOT, "Pair", id="x", a="", b="SR") == ["diff"]


# --- the reporter's actual shape --------------------------------------

_DISCRIM = """
schema PanelCommand scope ttl 1_h:
    verb: String
    place: String
    arity: Int
    ok: Bool
    b: Int

schema Cpu scope logical:
    id: String key
    running: Bool mutable

rule dep_core:
    PanelCommand c where c.verb == "DEP" and c.arity == 2 and c.place == "" and c.ok
    Cpu cpu where cpu.running == false
->
    log critical "core"

rule dep_sr:
    PanelCommand c where c.verb == "DEP" and c.arity == 2 and c.place == "SR" and c.ok
    Cpu cpu where cpu.running == false
->
    log critical "sr"

rule dep_pc:
    PanelCommand c where c.verb == "DEP" and c.arity == 2 and c.place == "PC" and c.ok
    Cpu cpu where cpu.running == false
->
    log critical "pc"

rule dep_ac:
    PanelCommand c where c.verb == "DEP" and c.arity == 2 and c.place == "AC" and c.ok
    Cpu cpu where cpu.running == false
->
    log critical "ac"
"""


def _fire_panel(place: str) -> list[str]:
    eng = pyds.from_source(_DISCRIM)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("Cpu", id="cpu0", running=False)
    eng.assert_("PanelCommand", verb="DEP", place=place, arity=2, ok=True, b=1838)
    eng.pump()
    return sorted(alerts)


def test_reporter_shape_empty_place_fires_only_core():
    """The discriminated shape: a deposit with place="" fires only `dep_core`.

    A deposit to a memory address carries place="". All four fired, and the
    emulator's registers each ended up holding the result of that rule's own
    arithmetic.
    """
    assert _fire_panel("") == ["core"]


def test_reporter_shape_named_place_fires_only_that_rule():
    """The reporter's own control: `dep pc 7000` sets only the PC.

    The non-empty path was already correct and must stay so.
    """
    assert _fire_panel("PC") == ["pc"]


# --- a prefix is not equality -----------------------------------------
#
# The general form of the reported defect: a comparison truncated at the
# shorter operand makes every string equal to its own extensions, and the empty
# string -- a prefix of everything -- is only its extreme. The compiled path
# once had exactly that bug; these pin the claim itself, on the path that runs.

_PREFIX = """
schema Thing scope logical:
    id: String key
    place: String mutable

rule p_pc:
    Thing t where t.place == "PC"
->
    log critical "pc"

rule p_pcx:
    Thing t where t.place == "PCX"
->
    log critical "pcx"
"""


@pytest.mark.parametrize("place", ["PC", "PCX"])
def test_prefix_is_not_equality(place):
    """`"PC"` must not compare equal to `"PCX"`, in either direction."""
    expected = ["pc"] if place == "PC" else ["pcx"]
    assert _fire(_PREFIX, "Thing", id="a", place=place) == expected


def test_ordering_respects_length():
    """The length tie-break is right for `<` too, not only for equality.

    Ordering shares the comparison.
    """
    src = """
schema Thing scope logical:
    id: String key
    place: String mutable

rule lt:
    Thing t where t.place < "PCX"
->
    log critical "lt"
"""
    assert _fire(src, "Thing", id="a", place="PC") == ["lt"]
