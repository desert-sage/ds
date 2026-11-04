# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""A typed callback that raises has FAILED, and libds is told.

libds acts on the status a typed callback returns ([NCBK.1.5]): a failed
`call` reaches pump, and a persistence failure is not lost ([NCBK.7.5]).

`persist:` is deferred, so no v1 program feeds the samples plane and nothing
here can make a sample fail.

These pin the STATUS and not whether the action event appears in the stream.

The exception reaches the caller (PYTHON_BINDING.md §2.3): the first one of
the engine call is the __cause__ of the error a failed call raises, and one
that nothing failed, or a later one, goes to sys.unraisablehook. These tests
capture the hook to show each exception lands in exactly one of the two.
"""

import sys

import pytest

import pyds

DS_ERR_ACTION_FAILED = -202


class _BoomError(Exception):
    pass


def _boom(*_args):
    raise _BoomError("handler failed")


@pytest.fixture
def unraisable(monkeypatch):
    got = []
    monkeypatch.setattr(sys, "unraisablehook", got.append)
    return got


def _pump_status(eng):
    """pump(); the libds status it raised with, or 0."""
    try:
        eng.pump()
    except pyds.Error as e:
        return int(e.status)
    return 0


def _pump_error(eng):
    """pump(), which must raise; the pyds.Error it raised."""
    with pytest.raises(pyds.Error) as caught:
        eng.pump()
    return caught.value


class _Counted:
    """A callback that raises a _BoomError numbered by its invocation."""

    def __init__(self):
        self.n = 0

    def __call__(self, *_args):
        self.n += 1
        raise _BoomError(f"raise {self.n}")


_CALL = """
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
    call svc.foo nocooldown as "c"
"""


def test_a_call_that_raised_is_reported_by_pump_as_its_cause(unraisable):
    eng = pyds.from_source(_CALL)
    eng.set_call_callback(_boom)
    eng.assert_("Trig", v=1)

    error = _pump_error(eng)
    assert error.status == DS_ERR_ACTION_FAILED
    assert type(error.__cause__) is _BoomError
    assert unraisable == []


def test_only_the_first_exception_is_the_cause_and_a_later_one_is_reported(unraisable):
    eng = pyds.from_source(_CALL)
    boom = _Counted()
    eng.set_call_callback(boom)
    eng.assert_("Trig", v=1)
    eng.assert_("Trig", v=2)

    error = _pump_error(eng)
    assert boom.n == 2
    assert str(error.__cause__) == "raise 1"
    assert [str(u.exc_value) for u in unraisable] == ["raise 2"]


def test_an_exception_is_kept_until_the_call_returns(unraisable):
    """The first exception reaches the hook when pump() returns.

    The observer raises on every event, the ActionCall before the call
    callback among them, so when the callback runs all but the first are
    with the hook.
    """
    eng = pyds.from_source(_CALL)
    eng.assert_("Trig", v=1)
    observer = _Counted()
    eng.on_event = observer
    at_call = []
    eng.set_call_callback(lambda _req: at_call.append((observer.n, len(unraisable))))

    eng.pump()
    ((raised, reported),) = at_call
    messages = [str(u.exc_value) for u in unraisable]
    assert raised > 0
    assert messages[:reported] == [f"raise {i}" for i in range(2, raised + 1)]
    assert sorted(messages) == sorted(f"raise {i}" for i in range(1, observer.n + 1))


def test_an_exception_reported_after_its_call_is_not_a_later_calls_cause(unraisable):
    eng = pyds.from_source(_CALL)
    observer = _Counted()
    eng.on_event = observer
    eng.set_call_callback(lambda _req: None)
    eng.assert_("Trig", v=1)
    eng.pump()
    reported = len(unraisable)
    assert reported == observer.n > 0

    eng.on_event = None
    eng.set_call_callback(_boom)
    eng.assert_("Trig", v=2)
    error = _pump_error(eng)
    assert str(error.__cause__) == "handler failed"
    assert len(unraisable) == reported


def test_a_call_that_returned_is_not(unraisable):
    """The control: the same program with a handler that returns."""
    eng = pyds.from_source(_CALL)
    calls = []
    eng.set_call_callback(calls.append)
    eng.assert_("Trig", v=1)

    assert _pump_status(eng) == 0
    assert len(calls) == 1
    assert unraisable == []


_CACHE = """
schema Trig scope logical:
    v: Int key

rule cache_value:
    Trig t
->
    cache key: "last" value: t.v
"""


def test_a_persistence_write_that_raised_is_reported_and_the_cache_keeps_it(unraisable):
    eng = pyds.from_source(_CACHE)
    events = []
    eng.on_event = events.append
    eng.on_cache_set = _boom
    eng.assert_("Trig", v=1)

    error = _pump_error(eng)
    assert error.status == DS_ERR_ACTION_FAILED, "a persistence failure is reported ([NCBK.7.5])"
    assert type(error.__cause__) is _BoomError
    # ...and not rolled back: the engine's cache took the write first.
    assert [e.key for e in events if isinstance(e, pyds.events.ActionCacheSet)] == ["last"]
    assert unraisable == []


def test_the_stream_callback_is_an_observer(unraisable):
    """[NCBK.1.5]: a stream callback's failure changes nothing, pump included."""
    eng = pyds.from_source(_CALL)
    eng.on_event = _boom
    calls = []
    eng.set_call_callback(calls.append)
    eng.assert_("Trig", v=1)

    assert _pump_status(eng) == 0
    assert len(calls) == 1
    assert unraisable and all(type(u.exc_value) is _BoomError for u in unraisable)
