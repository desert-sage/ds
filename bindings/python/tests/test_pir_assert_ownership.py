# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""An `emit` reaches working memory exactly once.

The terminal node owns the assert action, and nothing else contributes one. This
pins that an `emit` produces exactly one `fact_assert`.
"""

import pytest

import pyds

SRC = """
schema Trig scope logical:
    v: Int key

schema Alert scope logical:
    src_v: Int key

rule fire_once:
    Trig t
->
    emit Alert logical src_v: t.v
"""

# One test is enough: every schema an `emit` names is the artefact's own. No
# host registers a schema ([NFCT.1.1]), and a rule cannot emit an `ambient`
# schema ([LSCP.2.5.1]).


def _assert_events(eng, events):
    """Drive the rule and return the fact_assert events it produced.

    The COUNT OF EVENTS is the measurement, deliberately, not `len(facts)`.
    `Alert` is keyed on `src_v`, so a duplicate emit would carry the same key
    and identity upsert ([LFAC.1.7]) would collapse the two into one
    working-memory fact — invisible to `len(facts)`. The stream event fires
    per assert, so it would see the action run twice even when WM does not.
    """
    eng.assert_("Trig", v=1)
    eng.pump()
    return [e for e in events if isinstance(e, pyds.events.FactAssert)]


def test_emit_fires_once_for_a_schema_declared_only_in_the_artefact():
    """An emit fires once for a schema the artefact alone declares.

    The two `fact_assert` events are the host's `Trig` and the rule's one
    `Alert`.
    """
    eng = pyds.Engine()
    events = []
    try:
        eng.load_dsc(pyds.compile(SRC, file="pir_assert.ds"))
        eng.on_event = events.append
        assert len(_assert_events(eng, events)) == 2
    finally:
        eng.close()


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-q"]))
