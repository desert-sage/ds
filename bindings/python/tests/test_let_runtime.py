# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LHS `let` bindings.

`let <name> = <expr>` in the LHS computes a value once at
activation time; later patterns / where clauses + the RHS can
reference `?<name>` (or via the binding's resolved name shape).
"""

from log_sink import capture_critical

import pyds

_LET_RHS_USE = """
schema Reading scope logical:
    entity_id: String key
    state: Float mutable

schema Probe scope logical:
    delta: Float key

rule emit_scaled:
    Reading r
->
    let scaled = r.state * 100.0
    emit Probe logical delta: scaled
"""


def test_let_arith_value_threads_into_rhs_emit():
    """A `let` computed once reaches an `emit` in the RHS.

    `let scaled = r.state * 100` computes a value once;
    `emit Probe delta: scaled` pulls it into the new fact's slot. The Probe's
    delta should equal r.state * 100.
    """
    eng = pyds.from_source(_LET_RHS_USE)
    events = []
    eng.on_event = events.append

    eng.assert_("Reading", entity_id="dev1", state=2.5)
    eng.pump()
    # Two asserts: Reading + Probe.
    asserts = [e for e in events if isinstance(e, pyds.events.FactAssert)]
    assert len(asserts) == 2, f"got {asserts!r}"
    # fact_count includes both.
    assert len(eng.facts) == 2, len(eng.facts)


_WHERE_ARITH = """
schema Reading scope logical:
    entity_id: String key
    a: Float mutable
    b: Float mutable

rule alert_high_sum:
    Reading r where (r.a + r.b) > 10.0
->
    log critical "{r.entity_id}"
"""


def test_inline_arith_predicate_fires_on_high_sum():
    """The same arithmetic, written in the where-clause directly, fires the same way."""
    eng = pyds.from_source(_WHERE_ARITH)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="dev1", a=6.0, b=7.0)
    eng.pump()
    assert alerts == ["dev1"], f"arith predicate didn't fire: {alerts!r}"


def test_inline_arith_predicate_silent_on_low_sum():
    eng = pyds.from_source(_WHERE_ARITH)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Reading", entity_id="dev1", a=3.0, b=4.0)
    eng.pump()
    assert alerts == [], f"arith fired on low sum: {alerts!r}"
