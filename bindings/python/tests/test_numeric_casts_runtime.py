# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""End-to-end test for the numeric `::` conversion casts (LCST.4.5).

Float->Int (truncate), Float->String (canonical ds_fmt_float), String->Float?
(parse; null on failure, feeding `??`), Int->Float (widening) — exercised through
the runtime adapters in `where`-predicate position, a non-interpolation context.
"""

from log_sink import capture_critical

import pyds


def _fires(src: str, schema: str, **slots) -> list[str]:
    eng = pyds.from_source(src)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_(schema, **slots)
    eng.pump()
    return alerts


_FLOAT_TO_INT = """
schema S scope logical:
    entity_id: String key
    f: Float mutable

rule r:
    S s where s.f::Int == 3
->
    log critical "trunc"
"""


def test_float_to_int_truncates():
    # 3.7 -> 3 (toward zero) -> == 3 fires; 3.1 also -> 3.
    assert _fires(_FLOAT_TO_INT, "S", entity_id="a", f=3.7) == ["trunc"]
    assert _fires(_FLOAT_TO_INT, "S", entity_id="a", f=4.9) == []


_INT_TO_FLOAT = """
schema S scope logical:
    entity_id: String key
    i: Int mutable

rule r:
    S s where s.i::Float > 4.5
->
    log critical "wide"
"""


def test_int_to_float_widens():
    assert _fires(_INT_TO_FLOAT, "S", entity_id="a", i=5) == ["wide"]
    assert _fires(_INT_TO_FLOAT, "S", entity_id="a", i=4) == []


_FLOAT_TO_STRING = """
schema S scope logical:
    entity_id: String key
    f: Float mutable

rule r:
    S s where s.f::String == "42.0"
->
    log critical "canon"
"""


def test_float_to_string_canonical():
    # Keeps the `.0` on a whole float (42.0 -> "42.0", not "42").
    assert _fires(_FLOAT_TO_STRING, "S", entity_id="a", f=42.0) == ["canon"]
    assert _fires(_FLOAT_TO_STRING, "S", entity_id="a", f=42.5) == []


_FLOAT_TO_STRING_INF = """
schema S scope logical:
    entity_id: String key
    f: Float mutable

rule r:
    S s where s.f::String == "inf"
->
    log critical "inf"
"""


def test_float_to_string_non_finite():
    # [LDET.3.2.7]: Inf is a valid Float value (only NaN is rejected at
    # ingress) and Float::String renders the canonical ±Inf text form "inf" /
    # "-inf" (ds_fmt_float, the same text as the display plane). +Inf::String
    # matches "inf"; -Inf::String does not (it is "-inf").
    assert _fires(_FLOAT_TO_STRING_INF, "S", entity_id="a", f=float("inf")) == ["inf"]
    assert _fires(_FLOAT_TO_STRING_INF, "S", entity_id="a", f=float("-inf")) == []
    assert _fires(_FLOAT_TO_STRING_INF, "S", entity_id="a", f=1.0) == []


_STRING_TO_FLOAT = """
schema P scope logical:
    entity_id: String key
    txt: String mutable

rule ok:
    P p where p.txt::Float? ?? 0.0 > 1.0
->
    log critical "parsed"
"""


def test_string_to_float_parses():
    assert _fires(_STRING_TO_FLOAT, "P", entity_id="p", txt="2.5") == ["parsed"]


def test_string_to_float_null_does_not_fire():
    # Unparseable -> null -> `?? 0.0` -> 0.0, not > 1.0: the fallible parse fed
    # the LNUL stack.
    assert _fires(_STRING_TO_FLOAT, "P", entity_id="p", txt="not-a-number") == []


_STRING_TO_BOOL = """
schema P scope logical:
    entity_id: String key
    txt: String mutable

rule r:
    P p where p.txt::Bool? == true
->
    log critical "yes"
"""


def test_string_to_bool_parses_true_false_null():
    # LCST.4.5.5: exactly "true"/"false" parse; anything else
    # -> null -> (null == true) is Kleene-null -> no fire. Case-sensitive.
    assert _fires(_STRING_TO_BOOL, "P", entity_id="p", txt="true") == ["yes"]
    # "false" parses to Bool false; false == true -> no fire.
    assert _fires(_STRING_TO_BOOL, "P", entity_id="p", txt="false") == []
    # Unparseable -> null -> (null == true) Kleene-null -> no fire (fed LNUL).
    assert _fires(_STRING_TO_BOOL, "P", entity_id="p", txt="yes") == []
    # Case-sensitive: "True" is not accepted -> null -> no fire.
    assert _fires(_STRING_TO_BOOL, "P", entity_id="p", txt="True") == []


# unit-Float -> Float (strip tag) is covered at compile time by
# specs/conformance/compiler/LCST.4.5.2_unit_to_float_ok and lowers to
# the same "identity" no-op as Float -> <unit> below (which this exercises at
# runtime). A dedicated unit-Float -> Float runtime test would need to assert a
# value into a unit-typed slot, which hits a separate pyds unit-slot binding
# path (unrelated to the cast); the cast itself is a compile-time no-op.


# `kelvin` is `units.core`'s anchor, in scope with no import ([LUNI.4.1.2]),
# so the program declares no unit: a redeclaration is [LIMP.5.1.5]'s refusal.
_FLOAT_TO_UNIT = """
schema R scope logical:
    entity_id: String key
    x: Float mutable

rule r:
    R p where p.x::kelvin > 5.0
->
    log critical "big"
"""


def test_float_to_unit_is_identity_noop():
    # LCST.4.5.2 / LUNI.8.5 — Float -> <unit> asserts the tag (tag-only, no
    # affine); a runtime no-op, so the predicate behaves as the value.
    assert _fires(_FLOAT_TO_UNIT, "R", entity_id="p", x=10.0) == ["big"]
    assert _fires(_FLOAT_TO_UNIT, "R", entity_id="p", x=2.0) == []
