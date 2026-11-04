# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`after <dur>:` clauses on libds's Rete engine.

The compiler gives each after-clause a timer schema and a follow-up rule that
matches the timer and the clock tick with a fire guard of
`now() >= timer.fire_at`; the runtime cycles the $ClockTick fact each pump, so
the follow-up re-activates on every clock advance until its guard holds.

`as <expr>` supersedure (LRST.1.1) keys the timer's corr slot, and a re-fire
with the same key retracts the pending timer by a ds_retract_corr sweep, as a
call's correlation is retracted. A body that reads a parent-LHS binding reads
it through a capture fact (LTAC.3.5).
"""

from __future__ import annotations

from log_sink import capture_critical

import pyds

_AFTER_SIMPLE = """
schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    log critical "now"
    after 5s:
        log critical "later"
"""


def _compile_with_rete(source: str) -> bytes:
    return pyds.compile(source, file="t.ds")


def test_after_clause_fires_after_window_elapses_on_ds_rete():
    """An after-clause fires once its window elapses, and once only.

    The outer rule fires immediately on Trig assert (asserting the Timer fact
    via the compiler-synthesised RHS action). The follow-up rule's pattern
    (Timer x ClockTick) becomes activatable on every pump's tick cycle but
    suppressed by fire_guard until clock passes fire_at; once past, the body
    fires + the timer is retracted via ds_retract_token_fact so
    refraction-aware re-fires don't loop.
    """
    dsc = _compile_with_rete(_AFTER_SIMPLE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Trig", v=1)
    eng.pump()
    # Outer rule already fired the immediate alert; timer scheduled
    # for fire_at = 5s (asserted but not yet fireable).
    assert alerts == ["now"], f"outer rule didn't fire immediate alert: {alerts!r}"

    # Just under the after-duration; follow-up suppressed by guard.
    eng.clock.set(4_000_000_000)
    eng.pump()
    assert alerts == ["now"], f"after-clause fired before window elapsed: {alerts!r}"

    # Past the window — follow-up's fire_guard goes true, body fires.
    eng.clock.set(6_000_000_000)
    eng.pump()
    assert alerts == ["now", "later"], f"after-clause didn't fire after window: {alerts!r}"

    # One more pump past the window — the timer was retracted by
    # ds_retract_token_fact at end of follow-up RHS, so no second
    # firing even with cycle_generation bumped + fresh ClockTick.
    eng.clock.set(7_000_000_000)
    eng.pump()
    assert alerts == ["now", "later"], f"after-clause re-fired after retract: {alerts!r}"


_AFTER_TWO = """
schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    log critical "now"
    after 5s:
        log critical "five"
    after 10s:
        log critical "ten"
"""


def test_two_after_clauses_fire_in_order_on_ds_rete():
    """Two top-level after-clauses fire in clock order.

    Each gets its own Timer schema ($Timer_outer_0, $Timer_outer_1) and its
    own follow-up rule. Their fire_guards differ only in the bound fire_at; the agenda
    serves them in clock order regardless of source order.
    """
    dsc = _compile_with_rete(_AFTER_TWO)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Trig", v=1)
    eng.pump()
    eng.clock.set(7_000_000_000)
    eng.pump()
    eng.clock.set(15_000_000_000)
    eng.pump()
    assert alerts == ["now", "five", "ten"], f"after-clauses fired out of order: {alerts!r}"


_AFTER_NESTED = """
schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    log critical "now"
    after 5s:
        log critical "first"
        after 5s:
            log critical "second"
"""


def test_nested_after_chains_through_outer_then_inner_on_ds_rete():
    """An inner `after`'s window starts when the outer follow-up fires (LTAC.6.2.2).

    The inner clause's timer-assert lands in the outer follow-up's RHS, so
    its fire_at clock starts at the outer follow-up's fire time, not at
    parent-rule fire time. With outer=5s and inner=5s scheduled at parent
    fire (t=0), expect:

        t=0 → parent fires "now", schedules outer Timer (fire_at=5s).
        t=5s → outer follow-up fires "first", schedules inner Timer
               (fire_at=10s). Outer Timer retracted by
               ds_retract_token_fact at end of outer-follow-up RHS.
        t=10s → inner follow-up fires "second". Inner Timer retracted.

    Without the parent-then-child order, both timers would fire in
    the same window.
    """
    dsc = _compile_with_rete(_AFTER_NESTED)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Trig", v=1)
    eng.pump()
    assert alerts == ["now"], f"after #0: {alerts!r}"

    # 4s in — outer Timer not yet at fire_at; inner Timer doesn't
    # exist yet (outer follow-up hasn't fired).
    eng.clock.set(4_000_000_000)
    eng.pump()
    assert alerts == ["now"], f"premature outer fire: {alerts!r}"

    # 6s — outer Timer fires; inner Timer asserted at this tick
    # with fire_at = 6s + 5s = 11s.
    eng.clock.set(6_000_000_000)
    eng.pump()
    assert alerts == ["now", "first"], f"after outer fire: {alerts!r}"

    # 9s — inner Timer asserted at 6s, fire_at=11s. Still pending.
    eng.clock.set(9_000_000_000)
    eng.pump()
    assert alerts == ["now", "first"], f"premature inner fire: {alerts!r}"

    # 12s — past inner fire_at.
    eng.clock.set(12_000_000_000)
    eng.pump()
    assert alerts == ["now", "first", "second"], f"inner did not fire: {alerts!r}"

    # One more pump well past — the inner Timer was retracted at
    # end of inner-follow-up RHS, so no second firing.
    eng.clock.set(20_000_000_000)
    eng.pump()
    assert alerts == ["now", "first", "second"], f"inner re-fired after retract: {alerts!r}"


_AFTER_SUPERSEDE = """
schema Trig scope logical:
    entity_id: String key
    v: Int mutable

rule outer:
    Trig t
->
    log critical "now"
    after 5s as t.entity_id:
        log critical "later"
"""


def test_after_supersedure_replaces_prior_timer_on_ds_rete():
    """A re-fire with the same supersedure key replaces the pending timer.

    `after 5s as t.entity_id:` keys the Timer fact's corr slot on the
    per-fact entity_id. A re-fire with the same entity_id retracts the
    prior Timer (a ds_retract_corr sweep, as for a call) before asserting
    the new one. Only the second timer fires past its fire_at.
    """
    dsc = _compile_with_rete(_AFTER_SUPERSEDE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Trig", entity_id="dev1", v=1)
    eng.pump()
    eng.clock.set(1_000_000_000)
    # Second fact, same entity_id — retracts the first timer.
    eng.assert_("Trig", entity_id="dev1", v=2)
    eng.pump()
    # Past both timers' would-be fire_ats. Only the surviving
    # (second) timer fires.
    eng.clock.set(7_000_000_000)
    eng.pump()
    later_count = sum(1 for a in alerts if a == "later")
    assert later_count == 1, f"expected one supersedure-deduped fire, got: {alerts!r}"


def test_after_supersedure_independent_keys_on_ds_rete():
    """Timers under different supersedure keys both fire.

    Different keys give distinct Timer corr values, so distinct
    ds_retract_corr sweep targets.
    """
    dsc = _compile_with_rete(_AFTER_SUPERSEDE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Trig", entity_id="dev1", v=1)
    eng.assert_("Trig", entity_id="dev2", v=1)
    eng.pump()
    eng.clock.set(7_000_000_000)
    eng.pump()
    later_count = sum(1 for a in alerts if a == "later")
    assert later_count == 2, f"expected two independent fires, got: {alerts!r}"


# ---------------------------------------------------------------
# After-body capture facts (LTAC.3.5).
# ---------------------------------------------------------------


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


def test_after_body_sees_captured_slot_on_ds_rete():
    """After 100ms the follow-up fires and reads the snapshotted entity_id.

    The body's `m.entity_id` resolves through a per-activation
    $CaptureBindings fact joined to the timer on a ds_gensym corr.
    """
    dsc = _compile_with_rete(_AFTER_CAPTURE)
    logs: list[pyds.events.LogEvent] = []
    eng = pyds.Engine()
    eng.on_log = logs.append
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Motion", entity_id="kitchen", state="on")
    eng.pump()
    eng.clock.set(200_000_000)  # 200ms — past 100ms timer
    eng.pump()
    msgs = [r.message for r in logs]
    assert "on:kitchen" in msgs, msgs
    assert "off:kitchen" in msgs, msgs


def test_distinct_activations_carry_distinct_snapshots_on_ds_rete():
    """Two parent activations on different entity_ids each read their own snapshot.

    Each gets its own ds_gensym corr; the timers and capture facts pair via
    that corr. No cross-talk.
    """
    dsc = _compile_with_rete(_AFTER_CAPTURE)
    logs: list[pyds.events.LogEvent] = []
    eng = pyds.Engine()
    eng.on_log = logs.append
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Motion", entity_id="kitchen", state="on")
    eng.assert_("Motion", entity_id="hall", state="on")
    eng.pump()
    eng.clock.set(200_000_000)
    eng.pump()
    off_msgs = sorted(r.message for r in logs if r.message.startswith("off:"))
    assert off_msgs == ["off:hall", "off:kitchen"], off_msgs


def test_capture_survives_parent_retract_on_ds_rete():
    """Retracting the parent does not break the follow-up's read (LCCO.5.4).

    Capture is snapshot-always: once the capture fact has been asserted at
    parent fire time, it carries its own copy of the slot value.
    """
    dsc = _compile_with_rete(_AFTER_CAPTURE)
    logs: list[pyds.events.LogEvent] = []
    eng = pyds.Engine()
    eng.on_log = logs.append
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    h = eng.assert_("Motion", entity_id="bedroom", state="on")
    eng.pump()
    # Parent gone before the timer matures.
    eng.retract(h)
    eng.clock.set(200_000_000)
    eng.pump()
    off_msgs = [r.message for r in logs if r.message.startswith("off:")]
    assert off_msgs == ["off:bedroom"], off_msgs
