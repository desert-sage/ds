# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""`error <code>:` and `on <pred>:` continuations of a call, on libds's Rete engine.

They mirror the simplest cases from test_continuation_runtime.py. The compiler
gives each call with continuations a correlation key and emits one sibling
rule per Error / On clause beside the parent rule:

  - ErrorClause: alpha matches CallError, beta filters by
    `corr == <corr>` and (when the author wrote a non-empty
    code-pattern) `ds_error_code_matches(code, "<pattern>")`, terminal
    body runs the clause with `error` bound to pattern 0.

  - OnClause: alpha matches the service's response schema, beta
    filters by `corr == <corr>` and lowers the on-clause predicate as
    a join test; `response.<slot>` reads a slot of the response fact.

A TimeoutClause is a sibling whose LHS is two NOT-betas
(NOT-response + NOT-CallError, both gated on the call's corr), fired
by a timer once the window elapses.

The error-continuation tests cover family-prefix match, leaf-pattern
exact match, non-matching code silence, corr-mismatch silence, and
catch-all `error:` with body slot access. The on-continuation and
suppression-by-response tests assert a fact of the service's own
response schema.
"""

from __future__ import annotations

from log_sink import capture_critical

import pyds


def _compile_with_rete(source: str) -> bytes:
    return pyds.compile(source, file="t.ds")


_ERROR_FAMILY = """
schema Reply scope ttl 1_min:
    corr: String

service svc.foo:
    "test stub"
    response Reply

schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    call svc.foo nocooldown as "e1"
        error adapter:
            log critical "adapter-family"
"""


def test_error_sibling_matches_family_prefix_on_ds_rete():
    """An `error adapter:` sibling matches every `adapter.*` code (LECC.6.2).

    The match is ds_error_code_matches's segment-prefix semantics. Mirrors
    test_continuation_runtime::test_error_sibling_matches_family_prefix.
    """
    dsc = _compile_with_rete(_ERROR_FAMILY)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)  # absorb to keep adapter quiet
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    eng.pump()
    # Integrator-side: synthesise the failure response.
    eng.assert_("CallError", corr="e1", code="adapter.failed", message="x", ts=0)
    eng.pump()
    assert "adapter-family" in alerts, f"family-prefix sibling did not fire: {alerts!r}"


def test_error_sibling_silent_on_non_family_code_on_ds_rete():
    """`error adapter:` should NOT match `request.timeout`.

    The beta join's ds_error_code_matches test rejects non-prefix codes, so
    the sibling never activates.
    """
    dsc = _compile_with_rete(_ERROR_FAMILY)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("CallError", corr="e1", code="request.timeout", message="x", ts=0)
    eng.pump()
    assert "adapter-family" not in alerts, f"family sibling fired on non-family code: {alerts!r}"


_ERROR_LEAF = """
schema Reply scope ttl 1_min:
    corr: String

service svc.foo:
    "test stub"
    response Reply

schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    call svc.foo nocooldown as "e2"
        error adapter.throttled:
            log critical "adapter-throttled"
"""


def test_error_sibling_leaf_pattern_exact_match_on_ds_rete():
    """`error adapter.throttled:` matches exactly `adapter.throttled`."""
    dsc = _compile_with_rete(_ERROR_LEAF)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("CallError", corr="e2", code="adapter.throttled", message="x", ts=0)
    eng.pump()
    assert "adapter-throttled" in alerts, f"leaf sibling did not fire on exact code: {alerts!r}"


def test_error_sibling_silent_on_corr_mismatch_on_ds_rete():
    """A CallError with the wrong corr never activates the sibling, whatever its code.

    The sibling's beta filters by corr equality.
    """
    dsc = _compile_with_rete(_ERROR_FAMILY)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    eng.pump()
    # Same code-pattern (adapter.foo) but different corr.
    eng.assert_("CallError", corr="other-corr", code="adapter.foo", message="x", ts=0)
    eng.pump()
    assert "adapter-family" not in alerts, f"sibling fired on non-matching corr: {alerts!r}"


_ERROR_CATCHALL = """
schema Reply scope ttl 1_min:
    corr: String

service svc.foo:
    "test stub"
    response Reply

schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    call svc.foo nocooldown as "e3"
        error:
            log critical "any-error: {error.code}"
"""


def test_error_catchall_with_body_slot_access_on_ds_rete():
    """A catch-all `error:` matches every CallError with the right corr.

    It has no code_pattern, so the sibling skips the ds_error_code_matches
    join test. Body action interpolates `{error.code}` which
    lowers to Var(pattern_index=0, slot_index=1) over the CallError
    schema; the rete eval threads the bound fact's slot value through
    the format/str_cat path so the alert message carries the live code.
    """
    dsc = _compile_with_rete(_ERROR_CATCHALL)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("CallError", corr="e3", code="storage.unavailable", message="db down", ts=0)
    eng.pump()
    assert alerts == ["any-error: storage.unavailable"], (
        f"catch-all sibling didn't fire or didn't interpolate: {alerts!r}"
    )


_ON_RESPONSE = """
schema Reply scope ttl 1_min:
    corr: String
    ok: Bool

service svc.foo:
    "test stub"
    response Reply

schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    call svc.foo nocooldown as "r1"
        on response.ok == true:
            log critical "got ok"
"""


def test_on_continuation_fires_when_predicate_true_on_ds_rete():
    """An on-continuation fires when its predicate holds (LCCO.6.5)."""
    dsc = _compile_with_rete(_ON_RESPONSE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("Reply", corr="r1", ok=True)
    eng.pump()
    assert "got ok" in alerts


def test_on_continuation_compiles_under_emit_rete():
    """An on-continuation compiles to a well-formed DSC that loads and runs up to the call."""
    dsc = _compile_with_rete(_ON_RESPONSE)
    # The container's type is its FIRST ATOM's field number ([RFCS.19.4]).
    from pyds import atoms

    first = next(atoms.iter_atoms(dsc), None)
    assert first is not None and first.kind is pyds.AtomKind.DSC_HEADER, (
        f"expected a DscHeader first atom, got {dsc[:8]!r}"
    )
    # Loading should not error before any response has arrived.
    eng = pyds.Engine()
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    eng.pump()  # outer rule fires, asserts call request only.


_TIMEOUT_BARE = """
schema Reply scope ttl 1_min:
    corr: String
    ok: Bool

service svc.foo:
    "test stub"
    response Reply

schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    call svc.foo nocooldown as "tr1"
        timeout 10s:
            log critical "timed-out"
"""


def test_timeout_sibling_fires_after_window_elapses_on_ds_rete():
    """A timeout fires once its window elapses with no response, and once only.

    The parent rule asserts a $Timer_outer_timeout_0 fact alongside the
    call; the sibling LHS joins (Timer x ClockTick x NOT-CR x NOT-CE) on the
    call's corr with `now() >= timer.fire_at` as fire_guard. Before the
    duration elapses the guard is false and the body doesn't fire;
    once the clock crosses fire_at and no response/error has landed,
    the body fires + the Timer is retracted via ds_retract_token_fact
    so the next ClockTick doesn't re-activate.
    """
    dsc = _compile_with_rete(_TIMEOUT_BARE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Trig", v=1)
    eng.pump()
    assert alerts == [], f"timeout fired before window elapsed: {alerts!r}"

    # Clock under fire_at (10s); guard suppresses.
    eng.clock.set(5_000_000_000)
    eng.pump()
    assert alerts == [], f"timeout fired before window elapsed: {alerts!r}"

    # Past the window with no response/error — fire_guard goes
    # true, sibling fires.
    eng.clock.set(11_000_000_000)
    eng.pump()
    assert alerts == ["timed-out"], f"timeout sibling did not fire: {alerts!r}"

    # Another tick past the window — the timer was retracted by
    # ds_retract_token_fact at the end of the sibling RHS, so
    # there's no second firing.
    eng.clock.set(12_000_000_000)
    eng.pump()
    assert alerts == ["timed-out"], f"timeout sibling re-fired after retract: {alerts!r}"


def test_timeout_does_not_fire_under_window_on_ds_rete():
    """The fire_guard keeps the sibling from firing while `now() < timer.fire_at`.

    That holds over several pumps, each cycling a fresh ClockTick fact.
    """
    dsc = _compile_with_rete(_TIMEOUT_BARE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.assert_("Trig", v=1)
    for t_ns in (1_000_000_000, 3_000_000_000, 9_999_999_999):
        eng.clock.set(t_ns)
        eng.pump()
    assert alerts == [], f"timeout sibling fired before window elapsed: {alerts!r}"


# Suppression-by-response tests assert a fact of svc.foo's response schema.


def test_timeout_sibling_silent_when_response_arrives_first_on_ds_rete():
    """A matching response inside the window keeps the timeout from firing.

    The NOT-response beta gates out the sibling, so even after the clock
    crosses fire_at the body never fires.
    """
    dsc = _compile_with_rete(_TIMEOUT_BARE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.assert_("Trig", v=1)
    eng.pump()
    # Mid-window response arrives.
    eng.clock.set(2_000_000_000)
    eng.assert_("Reply", corr="tr1", ok=True)
    eng.pump()
    # Past the window — fire_guard is true but NOT-response blocks.
    eng.clock.set(11_000_000_000)
    eng.pump()
    assert "timed-out" not in alerts, f"timeout sibling fired despite the response: {alerts!r}"


def test_timeout_sibling_silent_on_corr_mismatch_response_on_ds_rete():
    """A response with a non-matching corr does NOT suppress the timeout.

    The NOT-pattern's corr equality fails, so the timeout sibling still fires
    once the window elapses.
    """
    dsc = _compile_with_rete(_TIMEOUT_BARE)
    alerts: list[str] = []
    eng = pyds.Engine()
    capture_critical(eng, alerts)
    eng.set_call_callback(lambda req: None)
    eng.load_dsc(dsc)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("Reply", corr="other", ok=True)
    eng.clock.set(11_000_000_000)
    eng.pump()
    assert "timed-out" in alerts, (
        f"timeout sibling did not fire under a corr-mismatched response: {alerts!r}"
    )
