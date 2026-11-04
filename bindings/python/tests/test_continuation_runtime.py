# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the sibling rules a call's continuations compile to.

The compile-side fixtures pin what compiles (LCCO.2.1 etc.); these
tests verify the lowered rules actually fire correctly
when response facts, of each service's own `response` schema, and
CallError facts arrive at runtime.

Exposes any bugs in:
- correlation threading from outer ds-call to sibling LHS
- response / CallError pattern matching with `corr "..."`
- timeout semantics (no response + no CallError + within)
- error-pattern matching via ds-error-code-matches
- `response.<X>` and `error.<X>` access in clause predicates / bodies
"""

from log_sink import capture_critical

import pyds


def _engine_with_call_capture(src: str):
    """Build an engine that captures call requests; return (eng, calls, alerts)."""
    eng = pyds.from_source(src)
    calls = []
    alerts = []
    eng.set_call_callback(calls.append)
    capture_critical(eng, alerts)
    return eng, calls, alerts


_RESPONSE_BASIC = """
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
    call svc.foo nocooldown as "c1"
        on response.ok == true:
            log critical "got-response"
"""


def test_response_sibling_fires_on_matching_corr():
    """The on-clause sibling rule fires when a response arrives with the matching correlation."""
    eng, calls, alerts = _engine_with_call_capture(_RESPONSE_BASIC)
    eng.assert_("Trig", v=1)
    eng.pump()
    # Outer rule fired and dispatched the call.
    assert len(calls) == 1, f"expected one call, got {calls!r}"
    assert calls[0]["correlation"] == "c1"

    # Now simulate the adapter responding.
    eng.assert_("Reply", corr="c1", ok=True)
    eng.pump()
    assert "got-response" in alerts, (
        f"sibling rule did not fire on the matching response: {alerts!r}"
    )


def test_response_sibling_silent_on_non_matching_corr():
    """A response with a different corr should not fire."""
    eng, _calls, alerts = _engine_with_call_capture(_RESPONSE_BASIC)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("Reply", corr="other", ok=True)
    eng.pump()
    assert "got-response" not in alerts, f"sibling fired on non-matching corr: {alerts!r}"


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


def test_error_sibling_matches_family_prefix():
    """`error adapter:` sibling rule matches every `adapter.*` code."""
    eng, _calls, alerts = _engine_with_call_capture(_ERROR_FAMILY)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("CallError", corr="e1", code="adapter.failed", message="x", ts=0)
    eng.pump()
    assert "adapter-family" in alerts, f"family-prefix sibling did not fire: {alerts!r}"


def test_error_sibling_silent_on_non_family_code():
    """`error adapter:` should NOT match `request.timeout`."""
    eng, _calls, alerts = _engine_with_call_capture(_ERROR_FAMILY)
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


def test_error_sibling_leaf_pattern_exact_match():
    """`error adapter.throttled:` matches exactly that code."""
    eng, _calls, alerts = _engine_with_call_capture(_ERROR_LEAF)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("CallError", corr="e2", code="adapter.throttled", message="x", ts=0)
    eng.pump()
    assert "adapter-throttled" in alerts, f"leaf-pattern sibling did not fire: {alerts!r}"


def test_error_sibling_leaf_silent_on_sibling_code():
    """`error adapter.throttled:` must NOT match `adapter.failed`."""
    eng, _calls, alerts = _engine_with_call_capture(_ERROR_LEAF)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("CallError", corr="e2", code="adapter.failed", message="x", ts=0)
    eng.pump()
    assert "adapter-throttled" not in alerts, f"leaf sibling fired on sibling code: {alerts!r}"


_ERROR_BODY_REF = """
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
    call svc.foo nocooldown as "eb1"
        error:
            log critical "{error.code}"
"""


def test_error_body_can_interpolate_error_code():
    """An error continuation body can read the CallError's `code` slot (LCCO.8).

    It is the standard `error.<slot>` chain, a real slot on the CallError
    schema that binds via the LHS pattern.
    """
    eng, _calls, alerts = _engine_with_call_capture(_ERROR_BODY_REF)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("CallError", corr="eb1", code="adapter.failed", message="rejected", ts=0)
    eng.pump()
    assert "adapter.failed" in alerts, f"error.code interpolation failed: {alerts!r}"


_TIMEOUT_BARE = """
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
    call svc.foo nocooldown as "tr1"
        timeout 10s:
            log critical "timed-out"
"""


_RESPONSE_PAYLOAD = """
schema Reply scope ttl 1_min:
    corr: String
    code: String

service svc.foo:
    "test stub"
    response Reply

schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    call svc.foo nocooldown as "p1"
        on response.code == "ok":
            log critical "code-ok"
"""


def test_response_payload_field_predicate_fires():
    """`response.<X>` reads slot X of the service's response schema (LCCO.6).

    The on-clause predicate `response.code == "ok"` should match a response
    whose `code` is "ok".
    """
    eng, _calls, alerts = _engine_with_call_capture(_RESPONSE_PAYLOAD)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("Reply", corr="p1", code="ok")
    eng.pump()
    assert "code-ok" in alerts, f"on-clause did not fire on matching response.code: {alerts!r}"


def test_response_payload_field_predicate_silent_on_mismatch():
    """response.code != "ok" should not fire."""
    eng, _calls, alerts = _engine_with_call_capture(_RESPONSE_PAYLOAD)
    eng.assert_("Trig", v=1)
    eng.pump()
    eng.assert_("Reply", corr="p1", code="fail")
    eng.pump()
    assert "code-ok" not in alerts, f"sibling fired on non-matching response.code: {alerts!r}"


def test_timeout_sibling_loads_and_fires_without_response():
    """The timeout sibling fires when no response or CallError arrives in its window (LCCO.7.2).

    The sibling joins on a Timer fact with a `now() >= timer.fire_at`
    guard, so it stays silent until the mock clock crosses the 10s window,
    then fires.
    """
    eng, _calls, alerts = _engine_with_call_capture(_TIMEOUT_BARE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.assert_("Trig", v=1)
    eng.pump()
    assert "timed-out" not in alerts, f"timeout fired before the window elapsed: {alerts!r}"
    eng.clock.set(11_000_000_000)  # past the 10s window
    eng.pump()
    assert "timed-out" in alerts, f"timeout sibling did not fire after the window: {alerts!r}"
