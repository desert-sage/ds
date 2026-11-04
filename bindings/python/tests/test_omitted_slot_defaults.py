# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An omitted slot takes `null`, never a zero of any type.

An emit path that zero-fills an unassigned slot with an Int 0, whatever the
slot's declared type, surfaces only as rendering, since nothing type-checks a
slot on the way out: `"{x.prefix}"` on an omitted String slot interpolates
"0".

The compiler closes the class: an `emit` that omits a non-nullable slot is
refused (`DS_VALIDATE_MISSING_SLOT`, [LGRA.13.11]; the fixture
`LGRA.13.11_missing_slot` pins it), so only a nullable slot can be omitted,
and it takes `null` ([LNUL.11.1]). These tests pin the runtime half for
String, Bool and Float: the omitted slot is `null`, which a zero of any type
would not be.
"""

from __future__ import annotations

import pyds


def _fired_messages(src: str) -> list[str]:
    """Compile `src`, assert a Seed and pump, return the `log` message text.

    Asserting the messages arrived at all is part of the control: the render
    rule matches only when the omitted slots are null, so a slot holding a
    zero leaves it silent rather than wrong.
    """
    eng = pyds.from_source(src)
    logs: list[pyds.events.LogEvent] = []
    eng.on_log = logs.append
    eng.assert_("Seed", go=1)
    eng.pump()
    assert logs, "the render rule never fired: an omitted slot was not null"
    return [rec.message for rec in logs]


def test_omitted_string_slots_are_null_not_zero():
    """String slots an emit leaves unset are null, not zero.

    The reported repro, reduced: a rule emits a fact leaving two String slots
    unset, and a second rule reads them.
    """
    src = (
        "schema Knob scope logical:\n"
        "    name:   String key\n"
        "    val:    String mutable\n"
        "    prefix: String? mutable\n"
        "    suffix: String? mutable\n"
        "\n"
        "schema Seed scope logical:\n"
        "    go: Int key\n"
        "\n"
        "rule make_knob:\n"
        "    Seed\n"
        "->\n"
        '    emit Knob logical name: "cc" val: "clang"\n'
        "\n"
        "rule render:\n"
        "    Knob k where k.prefix is null and k.suffix is null\n"
        "->\n"
        '    log info "[{k.val}]"\n'
    )
    assert "[clang]" in " ".join(_fired_messages(src))


def test_an_omitted_bool_slot_is_null_not_false():
    src = (
        "schema Flagged scope logical:\n"
        "    name: String key\n"
        "    is_on: Bool? mutable\n"
        "\n"
        "schema Seed scope logical:\n"
        "    go: Int key\n"
        "\n"
        "rule make:\n"
        "    Seed\n"
        "->\n"
        '    emit Flagged logical name: "f"\n'
        "\n"
        "rule render:\n"
        "    Flagged f where f.is_on is null\n"
        "->\n"
        '    log info "[{f.name}]"\n'
    )
    assert "[f]" in " ".join(_fired_messages(src))


def test_an_omitted_float_slot_is_null_not_zero():
    src = (
        "schema Reading scope logical:\n"
        "    name: String key\n"
        "    v:    Float? mutable\n"
        "\n"
        "schema Seed scope logical:\n"
        "    go: Int key\n"
        "\n"
        "rule make:\n"
        "    Seed\n"
        "->\n"
        '    emit Reading logical name: "r"\n'
        "\n"
        "rule render:\n"
        "    Reading r where r.v is null\n"
        "->\n"
        '    log info "[{r.name}]"\n'
    )
    assert "[r]" in " ".join(_fired_messages(src))
