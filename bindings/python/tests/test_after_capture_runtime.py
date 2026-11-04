# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for LTAC.3.5 capture-fact synthesis.

When an `after` body references a parent-LHS slot, the
compiler synthesises a `$CaptureBindings_<rule>_after_<N>`
fact alongside the timer. The follow-up rule joins the timer
and the capture fact on a `gensym*`-derived `corr` and reads
each captured slot through the same `?<binding>-<slot>`
variable name the original LHS pattern would have produced.

These tests pin: the captured value reaches the timer body,
distinct activations carry distinct snapshots, and the timer
body sees the snapshot value even after the parent fact is
retracted (LCCO.5.4 snapshot-always semantic).
"""

import pyds

_AFTER_CAPTURE = """
schema Motion scope logical:
    entity_id: String key
    state: String mutable

rule auto_off:
    Motion m where m.state == "on"
->
    log info "on:{m.entity_id}"
    after 100ms:
        log info "off:{m.entity_id}"
"""


def test_after_body_sees_captured_slot():
    """After the timer fires, the body's `m.entity_id` is the parent activation's snapshot."""
    eng = pyds.from_source(_AFTER_CAPTURE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Motion", entity_id="kitchen", state="on")
    eng.pump()
    eng.clock.set(200_000_000)  # 200ms — past 100ms timer
    eng.pump()

    msgs = [r.message for r in logs if r.category in ("auto_off", "$auto_off_after_0")]
    assert "on:kitchen" in msgs, msgs
    assert "off:kitchen" in msgs, msgs


def test_distinct_activations_carry_distinct_snapshots():
    """Two parent activations on different entity_ids each get their own capture fact.

    The bodies read independent values.
    """
    eng = pyds.from_source(_AFTER_CAPTURE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Motion", entity_id="kitchen", state="on")
    eng.assert_("Motion", entity_id="hall", state="on")
    eng.pump()
    eng.clock.set(200_000_000)
    eng.pump()

    off_msgs = sorted(r.message for r in logs if r.message.startswith("off:"))
    assert off_msgs == ["off:hall", "off:kitchen"], off_msgs


_AFTER_CAPTURE_JSON = """
schema Webhook scope logical:
    payload: Json key

rule fire:
    Webhook w
->
    log info "fire"
    after 100ms:
        log info "got:{w.payload.user.id}"
"""


def test_after_body_captures_json_path():
    """A multi-segment Json-path capture snapshots at parent fire time (LTAC.3.5, LCCO.5.5).

    It goes through `(ds-json-path …)`. The captured value rides on the capture
    fact's flattened slot and surfaces in the timer body interpolation.
    """
    eng = pyds.from_source(_AFTER_CAPTURE_JSON)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Webhook", payload={"user": {"id": "abc-123"}})
    eng.pump()
    eng.clock.set(200_000_000)
    eng.pump()

    msgs = [r.message for r in logs if r.message.startswith("got:")]
    assert msgs == ["got:abc-123"], msgs


def test_capture_snapshot_survives_parent_retract():
    """Capture is snapshot-always: a parent retracted before the timer fires (LCCO.5.4).

    Retracting the parent Motion fact via engine.retract() before the timer
    fires must NOT erase the snapshot value the timer body reads — that's the
    whole point of capturing at parent fire time.
    """
    eng = pyds.from_source(_AFTER_CAPTURE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    handle = eng.assert_("Motion", entity_id="kitchen", state="on")
    eng.pump()
    # Retract before timer fires.
    eng.retract(handle)
    eng.clock.set(200_000_000)
    eng.pump()

    off_msgs = [r.message for r in logs if r.message.startswith("off:")]
    assert off_msgs == ["off:kitchen"], off_msgs


def test_then_chain_bindings_flow_through_capture():
    """An after-body can reference any binding of a then-chain LHS (LTAC.3.5).

    The capture fact carries one slot per referenced (binding, slot) pair,
    whichever pattern in the chain introduced the binding.
    """
    src = """
schema Tick scope ttl 1_min:
    label: String
    ts: Time

rule chain:
    Tick a where a.label == "a"
    then Tick b within 5s where b.label == "b"
->
    log info "fired"
    after 100ms:
        log info "captured {a.label}->{b.label}"
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Tick", label="a", ts=0)
    eng.clock.set(1_000_000_000)
    eng.assert_("Tick", label="b", ts=1_000_000_000)
    eng.pump()
    eng.clock.set(1_200_000_000)
    eng.pump()

    msgs = [r.message for r in logs if r.message.startswith("captured")]
    assert msgs == ["captured a->b"], msgs


def test_after_body_bare_binding_fact_ref_capture():
    """A bare binding in an after-body captures the parent fact itself (LTAC.3.5).

    A bare BindingRef (e.g. `emit Trace target: m`) captures the parent fact's
    CLIPS pointer into a SCHEMA-typed slot. The follow-up rule reads it as a
    fact-address and the body's bare ref resolves correctly. Trace is `ttl`
    because a `logical` emit in an after-body is refused ([LLOG.11.9]).
    """
    src = """
schema Motion scope logical:
    state: Bool key

schema Trace scope ttl 1_h:
    target: Motion

rule r:
    Motion m where m.state == true
->
    log info "fired"
    after 100ms:
        emit Trace target: m
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    motion = eng.assert_("Motion", state=True)
    eng.pump()
    eng.clock.set(200_000_000)
    eng.pump()

    # One Trace, whose target is the original Motion fact.
    assert [t.slots["target"] for t in eng.facts.of("Trace")] == [motion]


def test_capture_fact_retracts_after_timer_fires():
    """Once the timer fires, the timer and the capture fact are retracted (LSCP.3.2, LTAC.4.2).

    The body runs and the follow-up rule retracts both. A second pump should
    not produce a duplicate timer firing.
    """
    eng = pyds.from_source(_AFTER_CAPTURE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Motion", entity_id="kitchen", state="on")
    eng.pump()
    eng.clock.set(200_000_000)
    eng.pump()
    # Advance further; if the capture fact / timer hadn't been
    # retracted, a re-evaluation could fire again.
    eng.clock.set(400_000_000)
    eng.pump()

    off_msgs = [r.message for r in logs if r.message.startswith("off:")]
    assert off_msgs == ["off:kitchen"], off_msgs
