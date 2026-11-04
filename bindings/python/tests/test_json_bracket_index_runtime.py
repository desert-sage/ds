# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""The lexer and grammar accept a Json bracket index in expression context.

`p.payload.tags[0] == "x"` compiles, and the path it lowers to reaches the
runtime's Json path reader as a `[N]` segment with no leading dot, which
json.c's path_step recognises.
"""

from log_sink import capture_critical

import pyds

_BRACKET_INDEX = """
schema Event scope logical:
    payload: Json key

rule first_tag:
    Event e where e.payload.tags[0] == "first"
->
    log critical "matched"
"""


def test_bracket_index_on_json_array_first_element():
    """The where-clause fires when the literal matches `payload.tags[0]`.

    Indexing into a Json array resolves at runtime via ds-json-path.
    """
    eng = pyds.from_source(_BRACKET_INDEX)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("Event", payload={"tags": ["first", "second"]})
    eng.pump()
    assert alerts == ["matched"], f"bracket-index where-clause didn't fire: {alerts!r}"


def test_bracket_index_on_json_array_no_match():
    """The rule does not fire when the array's index-0 element differs from the literal."""
    eng = pyds.from_source(_BRACKET_INDEX)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("Event", payload={"tags": ["other", "first"]})
    eng.pump()
    assert alerts == [], f"unexpected fire on non-matching first element: {alerts!r}"


_BRACKET_AFTER_DOTTED = """
schema Event scope logical:
    payload: Json key

rule on_first_thumbnail:
    Event e where e.payload.thumbnails[0] == "primary.png"
->
    log critical "primary"
"""


def test_bracket_after_dotted_object_key_path():
    """A mixed object-key + bracket path, `payload.thumbnails[0]`, resolves.

    It traverses an object key, then indexes the resulting array. Runtime
    path_step handles `thumbnails[0]` via successive steps; the lower must
    produce that exact path string (no `thumbnails.[0]`).
    """
    eng = pyds.from_source(_BRACKET_AFTER_DOTTED)
    alerts: list[str] = []
    capture_critical(eng, alerts)
    eng.assert_("Event", payload={"thumbnails": ["primary.png", "alt.png"]})
    eng.pump()
    assert alerts == ["primary"], f"object-then-bracket path didn't match: {alerts!r}"
