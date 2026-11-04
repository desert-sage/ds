# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for Json slot path access in where-clauses."""

import math
import sys

import pytest
from log_sink import capture_critical

import pyds

_JSON_PATH = """
schema Event scope logical:
    entity_id: String key
    payload: Json mutable

rule alert_high_temp:
    Event e where e.payload.temperature > 30.0
->
    log critical "{e.entity_id}"
"""


def test_json_path_predicate_fires_on_match():
    """`e.payload.temperature` reads the JSON path, and fires when it exceeds 30."""
    eng = pyds.from_source(_JSON_PATH)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Event", entity_id="kitchen", payload={"temperature": 35.5})
    eng.pump()
    assert alerts == ["kitchen"], f"expected fire on temp>30: {alerts!r}"


def test_json_path_predicate_silent_on_low_value():
    """The same predicate does NOT fire when the temperature is at or below the threshold."""
    eng = pyds.from_source(_JSON_PATH)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Event", entity_id="kitchen", payload={"temperature": 22.0})
    eng.pump()
    assert alerts == [], f"unexpected fire on low temp: {alerts!r}"


def test_json_has_predicate_distinguishes_present_keys():
    """LEXP.6 — `has(e.payload.x)` reads ds-json-has."""
    src = """
schema Event scope logical:
    entity_id: String key
    payload: Json mutable

rule has_key:
    Event e where has(e.payload.alert)
->
    log critical "{e.entity_id}"
"""
    eng = pyds.from_source(src)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Event", entity_id="a", payload={"alert": True})
    eng.assert_("Event", entity_id="b", payload={"other": 1})
    eng.pump()
    assert alerts == ["a"], f"has() didn't gate correctly: {alerts!r}"


# libds bounds a Json value: depth 16, 256 nodes, 16 KiB of string
# bytes, 24 KiB of text. A value over any of them is DS_ERR_JSON_LIMIT, a
# -2xx status, so the refusal is an ExecutionError.


def _nested(levels):
    """Return `levels` levels of nesting: levels-1 lists around an int.

    It is built by a loop, so a deep one costs no deep recursion here.
    """
    v = 1
    for _ in range(levels - 1):
        v = [v]
    return v


@pytest.mark.parametrize(
    ("at", "over"),
    [
        pytest.param(_nested(16), _nested(17), id="depth"),
        pytest.param([0] * 255, [0] * 256, id="nodes"),
        pytest.param("a" * 16_384, "a" * 16_385, id="string-bytes"),
    ],
)
def test_json_slot_at_a_limit_is_admitted_and_past_it_refused(at, over):
    """The largest value is admitted; the next is DS_ERR_JSON_LIMIT, and adds no fact."""
    eng = pyds.from_source(_JSON_PATH)
    eng.assert_("Event", entity_id="at", payload=at)
    with pytest.raises(pyds.ExecutionError) as refused:
        eng.assert_("Event", entity_id="over", payload=over)
    assert refused.value.status is pyds.Status.JSON_LIMIT
    assert len(eng.facts) == 1


def test_json_slot_a_million_deep_is_refused_not_a_crash():
    """A Json value a million deep is refused, not a crash: what the depth check is for.

    The conversion walks the Python value before libds sees a node, so without
    the check this overflowed the C stack. A crash here is the failure.
    """
    eng = pyds.from_source(_JSON_PATH)
    with pytest.raises(pyds.ExecutionError) as refused:
        eng.assert_("Event", entity_id="a", payload=_nested(1_000_000))
    assert refused.value.status is pyds.Status.JSON_LIMIT
    assert len(eng.facts) == 0


def test_cache_seed_text_at_the_limit_is_admitted_and_past_it_refused():
    """Seeded JSON text past 24 KiB is refused unread."""
    eng = pyds.from_source(_JSON_PATH)
    eng.cache.seed("at", "0" + " " * 24_575)
    with pytest.raises(pyds.ExecutionError) as refused:
        eng.cache.seed("over", "0" + " " * 24_576)
    assert refused.value.status is pyds.Status.JSON_LIMIT


# A Json float is finite (LGRA.5.8.10). pyds builds a Json slot's value
# through libds's ds_json_new_float, which refuses +inf, -inf and NaN with
# DS_ERR_JSON_NONFINITE; pyds surfaces that status as it is, an ExecutionError,
# as it surfaces DS_ERR_JSON_LIMIT. A Float slot still takes +inf (LEXP.4.2).


@pytest.mark.parametrize(
    "payload",
    [
        pytest.param(math.inf, id="inf"),
        pytest.param(-math.inf, id="-inf"),
        pytest.param(math.nan, id="nan"),
        pytest.param({"temperature": math.inf}, id="inf-in-an-object"),
        pytest.param([1.0, [math.nan]], id="nan-in-a-nested-array"),
    ],
)
def test_json_slot_holding_a_non_finite_float_is_refused(payload):
    """A non-finite float anywhere in a Json value is DS_ERR_JSON_NONFINITE, and adds no fact."""
    eng = pyds.from_source(_JSON_PATH)
    with pytest.raises(pyds.ExecutionError) as refused:
        eng.assert_("Event", entity_id="a", payload=payload)
    assert refused.value.status is pyds.Status.JSON_NONFINITE
    assert len(eng.facts) == 0


def test_json_slot_holding_the_largest_float_is_admitted():
    """The largest finite float is a float a Json value holds."""
    eng = pyds.from_source(_JSON_PATH)
    eng.assert_("Event", entity_id="a", payload={"temperature": sys.float_info.max})
    assert len(eng.facts) == 1


@pytest.mark.parametrize("text", ["1e400", "-1e400", "1.7976931348623159e308"])
def test_cache_seed_text_with_a_float_past_the_double_range_is_refused(text):
    """Seeded JSON text whose float rounds to an infinity is malformed: DS_ERR_PARSE."""
    eng = pyds.from_source(_JSON_PATH)
    with pytest.raises(pyds.Error) as refused:
        eng.cache.seed("k", text)
    assert refused.value.status is pyds.Status.PARSE
    assert "JSON float literal outside the double range" in str(refused.value)
