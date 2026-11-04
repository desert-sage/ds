# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LTAC.6.2.2 nested-after lowering.

A rule's `after` body may contain its own `after` clauses; the
inner timer is scheduled at the outer's firing time, not the
original parent activation. The compiler synthesises a separate
timer + follow-up rule per nested level, with each level's
parent follow-up rule emitting the next level's timer.

These tests pin: nested fires at outer-fire + inner-duration
(not parent-activation + sum), distinct nested clauses are
independent, and literal-only inner bodies work end-to-end.
"""

import pyds


def test_nested_after_fires_at_outer_plus_inner_duration():
    """`after 100ms: after 200ms: log` logs step 1 at t=100ms and step 2 at t=300ms.

    Step 2's time is the outer fire plus the inner duration.
    """
    src = """
schema Trig scope logical:
    label: String key

rule cascading:
    Trig
->
    log info "step 0"
    after 100ms:
        log info "step 1"
        after 200ms:
            log info "step 2"
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Trig", label="x")
    eng.pump()
    msgs = [r.message for r in logs if r.message.startswith("step")]
    assert msgs == ["step 0"], msgs

    eng.clock.set(150_000_000)  # 150ms — past 100ms inner only
    eng.pump()
    msgs = [r.message for r in logs if r.message.startswith("step")]
    assert msgs == ["step 0", "step 1"], msgs

    eng.clock.set(400_000_000)  # 400ms — past 100+200=300ms total
    eng.pump()
    msgs = [r.message for r in logs if r.message.startswith("step")]
    assert msgs == ["step 0", "step 1", "step 2"], msgs


def test_nested_after_inner_body_reads_parent_capture():
    """Nested-after bodies read parent-LHS slots through one shared capture fact.

    The outermost clause emits the capture fact (LTAC.6.2.2, LTAC.3.5). It
    stays in WM until the deepest leaf retracts it, so all levels see
    consistent snapshot values.
    """
    src = """
schema Motion scope logical:
    entity_id: String key
    state: Bool mutable

rule cascading:
    Motion m where m.state == true
->
    log info "fire {m.entity_id}"
    after 100ms:
        log info "outer {m.entity_id}"
        after 200ms:
            log info "inner {m.entity_id}"
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Motion", entity_id="kitchen", state=True)
    eng.pump()
    eng.clock.set(150_000_000)
    eng.pump()
    eng.clock.set(400_000_000)
    eng.pump()

    msgs = [r.message for r in logs if " " in r.message and "kitchen" in r.message]
    assert msgs == [
        "fire kitchen",
        "outer kitchen",
        "inner kitchen",
    ], msgs


def test_nested_after_doesnt_fire_until_outer_fires():
    """At t=200ms the outer (100ms) has fired but the inner (100+200=300ms) hasn't yet."""
    src = """
schema Trig scope logical:
    label: String key

rule cascading:
    Trig
->
    log info "fire"
    after 100ms:
        log info "outer"
        after 200ms:
            log info "inner"
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Trig", label="x")
    eng.pump()
    eng.clock.set(200_000_000)
    eng.pump()

    msgs = [r.message for r in logs if r.message in ("outer", "inner")]
    assert msgs == ["outer"], msgs
