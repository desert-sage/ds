# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A rule's call is streamed before the call callback runs ([IDSP.1.4], [NCBK.6.9]).

That holds whatever the callback does, and whether or not one is set.

The ``ActionCall`` event comes first; the callback's failure, or its absence,
reaches the caller only as ``pump()``'s status.
"""

import sys

import pytest

import pyds
from pyds import events

_SRC = """
schema Reading scope logical:
    id: String key

service svc.ping:
    kwarg id: String
    no response

rule ping:
    Reading r
->
    call svc.ping id: r.id nocooldown
"""


@pytest.fixture
def eng():
    with pyds.from_source(_SRC) as e:
        yield e


def _calls(seen):
    return [ev for ev in seen if isinstance(ev, events.ActionCall)]


def test_the_call_is_streamed_before_the_callback_runs(eng):
    order = []
    eng.on_event = lambda ev: order.append(type(ev).__name__)
    eng.set_call_callback(lambda req: order.append("callback"))
    eng.assert_("Reading", id="a")
    eng.pump()
    assert "ActionCall" in order and "callback" in order
    assert order.index("ActionCall") < order.index("callback")


def test_the_call_is_streamed_when_the_callback_raises(eng, monkeypatch):
    seen = []
    unraisable = []
    monkeypatch.setattr(sys, "unraisablehook", unraisable.append)

    def fail(req):
        raise RuntimeError("svc.ping is down")

    eng.on_event = seen.append
    eng.set_call_callback(fail)
    eng.assert_("Reading", id="a")
    with pytest.raises(pyds.ExecutionError) as caught:
        eng.pump()
    assert caught.value.status is pyds.Status.ACTION_FAILED
    assert type(caught.value.__cause__) is RuntimeError
    (call,) = _calls(seen)
    assert call.service == "svc.ping"
    assert unraisable == []


def test_the_call_is_streamed_with_no_callback_set(eng):
    seen = []
    eng.on_event = seen.append
    eng.assert_("Reading", id="a")
    with pytest.raises(pyds.StorageError) as caught:
        eng.pump()
    assert caught.value.status is pyds.Status.STORAGE_UNAVAILABLE
    (call,) = _calls(seen)
    assert call.service == "svc.ping"
