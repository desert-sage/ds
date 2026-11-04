# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A most-recent-by-ts LHS selection composes with cooldown and after-clause supersedure.

The selection is a positive pattern plus a `no` pattern over the same
schema with a strictly greater `ts`. It composes with:
- rule-level cooldown (a rate gate wraps the RHS) — the selected
  fact's slots are available inside the gate.
- after-clause `as <expr>` supersedure where the expr references
  the selected fact.
"""

import pyds

# Removed test_latest_with_rule_cooldown_lowers_with_rate_gate: it asserted on
# LoweringResult.clips_source — the CLIPS backend, removed; native rete is the
# sole backend — so it could only ever AttributeError. The latest+cooldown
# behavior it cared about is covered at runtime by
# test_latest_fires_once_for_a_single_activation below.


def test_latest_fires_once_for_a_single_activation():
    """A rule with cooldown and a most-recent selection fires the first time.

    The selected fact is resolved.
    """
    src = """
schema Trig scope logical:
    label: String key

schema Reading scope logical:
    val: Int key
    ts: Time

rule r cooldown 1_min:
    Trig t
    Reading recent
    no Reading newer where newer.ts > recent.ts
->
    log info "{t.label}={recent.val}"
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=42, ts=100)
    eng.assert_("Trig", label="x")
    eng.pump()

    fires = [r.message for r in logs if "=" in r.message]
    assert fires == ["x=42"], fires


def test_latest_value_in_after_supersedure_key():
    """An `after ... as <expr>:` key over the most-recent selection uses its slot values.

    The expr is evaluated at parent fire time, using the selected fact's slot
    values.

    [LRST.1.4] makes an Int `as` key legal. The conformance vector
    logical/LTAC.2.2.1_as_keyed_supersedure_int pins the supersedure itself
    on both runtimes; this test pins only that one timer fires.

    `Trig t where t.label == "x"` reads `t` so the binding is referenced
    ([LGRA.8.6]: an unreferenced pattern binding is
    DS_VALIDATE_UNREFERENCED_BINDING). The guard holds for the one Trig
    asserted, so it changes nothing the test observes. Without it the
    program is refused for that reason.
    """
    src = """
schema Trig scope logical:
    label: String key

schema Reading scope logical:
    val: Int key
    ts: Time

rule r:
    Trig t where t.label == "x"
    Reading recent
    no Reading newer where newer.ts > recent.ts
->
    log info "fired"
    after 100ms as recent.val:
        log info "timer fired"
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=7, ts=100)
    eng.assert_("Trig", label="x")
    eng.pump()
    eng.clock.set(200_000_000)
    eng.pump()

    msgs = [r.message for r in logs if r.message in ("fired", "timer fired")]
    assert msgs == ["fired", "timer fired"], msgs
