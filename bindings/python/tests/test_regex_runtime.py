# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the LREG.1 regex match operators (`~` / `!~`).

`<s> ~ /<pat>/<flags>` lowers to the regex-match builtin with the pattern and
flags as its operands; libds backs it with RE2 (`ds_re2.h`).
"""

from log_sink import capture_critical

import pyds

_REGEX_PRED = """
schema Msg scope logical:
    entity_id: String key
    text: String mutable

rule alert_abc_prefix:
    Msg m where m.text ~ /^abc/
->
    log critical "{m.entity_id}"
"""


def test_regex_match_fires_on_anchored_prefix_match():
    """`m.text ~ /^abc/` fires when the text starts with abc."""
    eng = pyds.from_source(_REGEX_PRED)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Msg", entity_id="m1", text="abcdef")
    eng.pump()
    assert alerts == ["m1"], f"regex predicate didn't fire: {alerts!r}"


def test_regex_match_silent_on_non_match():
    """`m.text ~ /^abc/` does not fire on text without that prefix."""
    eng = pyds.from_source(_REGEX_PRED)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Msg", entity_id="m1", text="xyzabc")
    eng.pump()
    assert alerts == [], f"regex predicate matched non-prefix: {alerts!r}"


_REGEX_NEG = """
schema Msg scope logical:
    entity_id: String key
    text: String mutable

rule alert_no_warn:
    Msg m where m.text !~ /WARN/
->
    log critical "{m.entity_id}"
"""


def test_regex_negated_match_inverts_predicate():
    """`!~` fires only when the regex does NOT match."""
    eng = pyds.from_source(_REGEX_NEG)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Msg", entity_id="ok", text="info: all clear")
    eng.assert_("Msg", entity_id="warn", text="WARN: high temp")
    eng.pump()
    assert alerts == ["ok"], f"!~ didn't filter correctly: {alerts!r}"


_REGEX_FLAGS = """
schema Msg scope logical:
    entity_id: String key
    text: String mutable

rule alert_case_insensitive:
    Msg m where m.text ~ /^abc/i
->
    log critical "{m.entity_id}"
"""


def test_regex_case_insensitive_flag():
    """`/^abc/i` matches regardless of case."""
    eng = pyds.from_source(_REGEX_FLAGS)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Msg", entity_id="lower", text="abcdef")
    eng.assert_("Msg", entity_id="upper", text="ABCDEF")
    eng.pump()
    assert sorted(alerts) == ["lower", "upper"], f"`i` flag didn't apply: {alerts!r}"
