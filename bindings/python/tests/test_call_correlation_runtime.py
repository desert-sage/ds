# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the LRST `as <expr>` correlation clause on call actions.

The correlation may be a string literal or a slot expression that resolves at
activation time.
"""

import pyds

_LITERAL = """
schema FooReply scope ttl 1_min:
    corr: String

service svc.foo:
    "test stub"
    response FooReply

schema Trig scope logical:
    v: Int key

rule outer:
    Trig
->
    call svc.foo nocooldown as "lit-corr"
"""


def test_call_literal_correlation_threads_to_callback():
    eng = pyds.from_source(_LITERAL)
    calls: list[dict] = []
    eng.set_call_callback(calls.append)

    eng.assert_("Trig", v=1)
    eng.pump()

    assert len(calls) == 1, calls
    assert calls[0]["correlation"] == "lit-corr", calls


_DYNAMIC = """
schema FooReply scope ttl 1_min:
    corr: String

service svc.foo:
    "test stub"
    response FooReply

schema Trig scope logical:
    entity_id: String key
    v: Int mutable

rule outer:
    Trig t
->
    call svc.foo nocooldown as t.entity_id
"""


def test_call_dynamic_correlation_resolves_to_slot_value():
    """`as t.entity_id` makes the bound slot value the outbound call's correlation."""
    eng = pyds.from_source(_DYNAMIC)
    calls: list[dict] = []
    eng.set_call_callback(calls.append)

    eng.assert_("Trig", entity_id="dev42", v=1)
    eng.pump()

    assert len(calls) == 1, calls
    assert calls[0]["correlation"] == "dev42", calls


_NONE = """
service svc.note:
    kwarg n: Int
    no response

schema Trig scope logical:
    v: Int key

rule outer:
    Trig t
->
    call svc.note n: t.v nocooldown
"""


def test_a_call_with_no_as_has_the_generated_correlation():
    """A call with no `as` carries the correlation the compiler generates (LCRS.3.1, LCCO.3.4).

    It is the per-activation `$<rule>_c<N>_<u>`, and the callback and
    the stream's action_call event see the same string.
    """
    eng = pyds.from_source(_NONE)
    calls: list[dict] = []
    events: list[pyds.events.Event] = []
    eng.set_call_callback(calls.append)
    eng.on_event = events.append

    eng.assert_("Trig", v=7)
    eng.pump()

    want = [("$outer_c0_g0", {"n": 7})]
    assert [(c["correlation"], c["args"]) for c in calls] == want, calls
    issued = [e for e in events if isinstance(e, pyds.events.ActionCall)]
    assert [(e.correlation, e.args) for e in issued] == want, issued
