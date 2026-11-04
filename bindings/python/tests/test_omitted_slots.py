# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An `emit` gives every non-nullable slot; a nullable slot left out is null.

[LGRA.13.11]: the compiler refuses an `emit` that omits a non-nullable slot
with DS_VALIDATE_MISSING_SLOT, and a nullable slot left out takes `null`,
which reaches Python as None. There is no "zero of the declared type", so an
omitted String slot cannot render "0" (test_omitted_slot_defaults.py).
"""

from __future__ import annotations

import pytest

import pyds

_SEED = """
schema Seed scope logical:
    go: Int key

"""


def test_omitting_a_non_nullable_slot_is_refused():
    src = _SEED + (
        "schema Knob scope logical:\n"
        "    name:   String key\n"
        "    prefix: String mutable\n"
        "\n"
        "rule make:\n"
        "    Seed\n"
        "->\n"
        '    emit Knob logical name: "cc"\n'
    )
    with pytest.raises(pyds.CompileRefusedError) as info:
        pyds.compile(src, file="missing.ds")
    assert "DS_VALIDATE_MISSING_SLOT" in info.value.diagnostics


@pytest.mark.parametrize("slot_type", ["String", "Bool", "Float", "Int"])
def test_an_omitted_nullable_slot_reads_none(slot_type):
    src = _SEED + (
        "schema Knob scope logical:\n"
        "    name: String key\n"
        f"    extra: {slot_type}? mutable\n"
        "\n"
        "rule make:\n"
        "    Seed\n"
        "->\n"
        '    emit Knob logical name: "cc"\n'
    )
    eng = pyds.from_source(src)
    eng.assert_("Seed", go=1)
    eng.pump()
    knobs = eng.facts.of("Knob")
    assert len(knobs) == 1, knobs
    assert knobs[0].slots["extra"] is None
