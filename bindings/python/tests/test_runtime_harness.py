# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Tests for the pyds runtime harness surface: assert_, pump and the fact count.

It activates the runtime category of the conformance suite per LTES.8 / RTIM.
"""

import pytest

import pyds


def _compile(source: str) -> bytes:
    # Native Rete is the sole backend: the .dsc MUST carry Rete atoms or no
    # rule fires at load — pyds.compile emits them.
    return pyds.compile(source, file="test.ds")


def _engine_with(source: str) -> pyds.Engine:
    eng = pyds.Engine()
    eng.load_dsc(_compile(source))
    return eng


# --------------------------------------------------------------
# fact_count
# --------------------------------------------------------------


def test_fact_count_starts_at_zero():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    assert len(eng.facts) == 0


# --------------------------------------------------------------
# assert_
# --------------------------------------------------------------


def test_assert_int_slot():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.assert_("Trig", v=42)
    assert len(eng.facts) == 1


def test_assert_returns_a_fact_id():
    """assert_ returns the fact's FactId, which retract() takes."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    h = eng.assert_("Trig", v=1)
    assert isinstance(h, pyds.FactId)
    assert h != 0


def test_retract_removes_fact():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    h = eng.assert_("Trig", v=1)
    assert len(eng.facts) == 1
    eng.retract(h)
    assert len(eng.facts) == 0


def test_retract_emits_fact_retract_stream_event():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    events = []
    eng.on_event = events.append
    h = eng.assert_("Trig", v=1)
    eng.retract(h)
    kinds = [e.kind for e in events]
    assert pyds.EventKind.FACT_ASSERT in kinds and pyds.EventKind.FACT_RETRACT in kinds


def test_assert_json_slot_with_dict():
    """A Json-typed slot accepts a Python dict.

    The value round-trips through ds_json_t and shows up as parsed JSON in callbacks.
    """
    eng = _engine_with("schema Sample scope logical:\n    payload: Json key\n")
    eng.assert_("Sample", payload={"k": 1, "nested": [True, None, "x"]})
    assert len(eng.facts) == 1


def test_assert_json_slot_with_scalar():
    """A Json slot accepts any JSON value at the top level, not just objects.

    That is int, float, bool, None and str.
    """
    eng = _engine_with("schema Sample scope logical:\n    payload: Json key\n")
    eng.assert_("Sample", payload=42)
    assert len(eng.facts) == 1


def test_assert_json_slot_with_list():
    eng = _engine_with("schema Sample scope logical:\n    payload: Json key\n")
    eng.assert_("Sample", payload=[1, 2, 3])
    assert len(eng.facts) == 1


def test_assert_json_slot_rejects_non_json_type():
    """A value that isn't JSON-serialisable is a TypeError before ds_engine_assert.

    A Python set, bytes or object is one.
    """
    eng = _engine_with("schema Sample scope logical:\n    payload: Json key\n")
    with pytest.raises(TypeError, match="cannot convert"):
        eng.assert_("Sample", payload={1, 2, 3})


def test_compile_helper_round_trips():
    """pyds.compile() returns DSC bytes that Engine.load_dsc accepts."""
    dsc = pyds.compile("schema Trig scope logical:\n    v: Int key\n")
    assert isinstance(dsc, bytes) and len(dsc) > 0
    eng = pyds.Engine()
    eng.load_dsc(dsc)
    eng.assert_("Trig", v=1)
    assert len(eng.facts) == 1


def test_log_callback_silent_drop_on_null():
    """No log cb registered → IARC.1.14 silent drop, no error.

    The property is the NULL-cb policy for a non-essential verb.
    `test_log_callback_receives_event` below pins delivery.
    """
    src = (
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig\n"
        "->\n"
        '    log critical "x"\n'
    )
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    eng.assert_("Trig", v=1)
    eng.pump()  # no exception


def test_log_callback_receives_event():
    """A rule firing `log warning "..."` calls on_log with level, category and message."""
    src = (
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig\n"
        "->\n"
        '    log warning "alert text"\n'
    )
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    events = []
    eng.on_log = events.append
    eng.assert_("Trig", v=1)
    eng.pump()
    assert events == [
        pyds.events.LogEvent(level=pyds.LogLevel.WARNING, category="r", message="alert text")
    ]


def test_on_metric_can_be_set_and_cleared():
    """on_metric takes a callable, reads back as it, and clears with None."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    metrics = []
    eng.on_metric = metrics.append
    assert eng.on_metric == metrics.append
    eng.on_metric = None
    assert eng.on_metric is None
    # Smoke test — basic engine doesn't emit metrics on
    # assert/pump in MVP; the wrap shape is what we're pinning.


def test_from_source_factory():
    """pyds.from_source() bundles compile + Engine + load_dsc."""
    eng = pyds.from_source("schema Trig scope logical:\n    v: Int key\n")
    assert isinstance(eng, pyds.Engine)
    eng.assert_("Trig", v=1)
    assert len(eng.facts) == 1


def test_assert_multi_slot_typed():
    eng = _engine_with(
        "schema Sample scope logical:\n"
        "    i: Int key\n"
        "    f: Float mutable\n"
        "    s: String mutable\n"
        "    b: Bool mutable\n"
    )
    eng.assert_("Sample", i=1, f=2.5, s="hi", b=True)
    assert len(eng.facts) == 1


def test_assert_unknown_schema_rejected():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(KeyError):
        eng.assert_("Bogus", v=1)


def test_assert_missing_slot_rejected():
    eng = _engine_with("schema Pair scope logical:\n    a: Int key\n    b: Int mutable\n")
    # A missing kwarg surfaces the per-slot "missing kwarg for slot <name>"
    # rejection (a mistyped slot name is covered by a separate test below).
    with pytest.raises(TypeError, match="missing kwarg for slot"):
        eng.assert_("Pair", a=1)


def test_assert_missing_hydrated_corr_slot_rejected():
    """A slot named `hydrated_corr` is an author's slot like any other.

    No clause in force gives the name a meaning (hydration is deferred), so
    omitting a non-nullable one is refused as any missing slot is, and
    supplying it is admitted: the control, so the refusal is the omission's.
    """
    eng = _engine_with(
        "schema Reading scope logical:\n    dev: String key\n    hydrated_corr: String mutable\n"
    )
    with pytest.raises(TypeError, match="missing kwarg for slot `hydrated_corr`"):
        eng.assert_("Reading", dev="a")
    eng.assert_("Reading", dev="a", hydrated_corr="x")
    assert len(eng.facts) == 1


def test_assert_misspelled_slot_rejected():
    """A right kwarg count with a wrong slot name names the unmatched slot.

    The diagnostic is the per-slot `missing kwarg` one.
    """
    eng = _engine_with("schema Pair scope logical:\n    a: Int key\n    b: Int mutable\n")
    with pytest.raises(TypeError, match="missing kwarg for slot `b`"):
        eng.assert_("Pair", a=1, typo=2)


def test_assert_extra_slot_rejected():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(TypeError, match="2 kwargs"):
        eng.assert_("Trig", v=1, extra=2)


def test_assert_wrong_type_int_slot_gets_string():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(TypeError, match="expected int"):
        eng.assert_("Trig", v="not-an-int")


def test_assert_bool_rejected_for_int_slot():
    """A bool is refused for an Int slot, though Python's bool is an int.

    Taking it would coerce True to 1 and False to 0 silently.
    """
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(TypeError, match="expected int"):
        eng.assert_("Trig", v=True)


@pytest.mark.parametrize("value", [3, 2**53 + 1, True])
def test_assert_int_passed_for_float_slot_rejected(value):
    """An int or a bool is refused for a Float slot (NFCT.2.3, no implicit conversion).

    That holds even for an int a double holds exactly. 2**53 + 1 is one a
    double cannot hold.
    """
    eng = _engine_with("schema F scope logical:\n    x: Float key\n")
    with pytest.raises(TypeError, match=r"slot `x`: expected float, got (int|bool)"):
        eng.assert_("F", x=value)
    assert len(eng.facts) == 0


def test_assert_float_passed_for_float_slot_accepted():
    eng = _engine_with("schema F scope logical:\n    x: Float key\n")
    eng.assert_("F", x=3.0)
    assert len(eng.facts) == 1


@pytest.mark.parametrize("slot", ["n", "t"])
@pytest.mark.parametrize("value", [1.9, 1.0, float("nan")])
def test_assert_float_passed_for_int_slot_rejected(slot, value):
    """A float is refused for an Int slot or a Time, even an integral one (NFCT.2.3).

    NFCT.2.3 admits no implicit conversion, and nothing is asserted.
    Truncating would turn 1.9 into 1, and a float timestamp has already lost
    its nanoseconds.
    """
    eng = _engine_with(
        "schema E scope logical:\n    id: Int key\n    n: Int mutable\n    t: Time mutable\n"
    )
    slots = {"id": 1, "n": 0, "t": 0}
    slots[slot] = value
    with pytest.raises(TypeError, match=f"slot `{slot}`: expected int, got float"):
        eng.assert_("E", **slots)
    assert len(eng.facts) == 0


def test_assert_bool_passed_for_int_slot_rejected():
    """A bool is refused for an Int slot: True and False are for Bool slots."""
    eng = _engine_with("schema E scope logical:\n    v: Int key\n")
    with pytest.raises(TypeError):
        eng.assert_("E", v=True)


# --------------------------------------------------------------
# pump
# --------------------------------------------------------------


def test_pump_default_budget():
    """A loaded engine with no fact pumps cleanly."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.pump()
    assert len(eng.facts) == 0


_DERIVES = (
    "schema Trig scope logical:\n"
    "    v: Int key\n"
    "\n"
    "schema Derived scope logical:\n"
    "    src_v: Int key\n"
    "\n"
    "rule derive:\n"
    "    Trig t\n"
    "->\n"
    "    emit Derived logical src_v: t.v\n"
)


def test_pump_refuses_a_positional_budget_and_runs_nothing():
    """pump() takes no argument (NLFC.2.2), and one is a TypeError before the engine.

    So the rule that would fire does not.
    """
    eng = _engine_with(_DERIVES)
    eng.assert_("Trig", v=1)
    with pytest.raises(TypeError, match="takes no arguments"):
        eng.pump(1)
    assert len(eng.facts) == 1
    eng.pump()
    assert len(eng.facts) == 2


def test_pump_refuses_a_budget_by_keyword():
    eng = _engine_with(_DERIVES)
    eng.assert_("Trig", v=1)
    with pytest.raises(TypeError, match="takes no keyword arguments"):
        eng.pump(budget_ns=1)
    assert len(eng.facts) == 1


def test_assert_then_pump_keeps_logical_fact():
    """A logical fact no rule consumes stays in working memory after a pump.

    Truth maintenance retracts nothing for it.
    """
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.assert_("Trig", v=42)
    assert len(eng.facts) == 1
    eng.pump()
    assert len(eng.facts) == 1


# --------------------------------------------------------------
# Clock control (RTIM.3)
# --------------------------------------------------------------


def test_clock_starts_in_live_mode():
    """A fresh engine is in live mode per RTIM.3."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    assert eng.clock.mode is pyds.ClockMode.LIVE


def test_clock_mode_round_trip():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.clock.mode = pyds.ClockMode.MOCK
    assert eng.clock.mode is pyds.ClockMode.MOCK
    # A str naming a member is taken too, and compares equal to it.
    eng.clock.mode = "live"
    assert eng.clock.mode == "live"


def test_a_mode_that_is_not_a_clock_mode_is_a_value_error():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(ValueError, match="ClockMode"):
        eng.clock.mode = "yesterday"
    assert eng.clock.mode is pyds.ClockMode.LIVE


@pytest.mark.parametrize("mode", [1, None, b"mock"])
def test_a_mode_that_is_not_a_str_is_a_type_error(mode):
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(TypeError, match="ClockMode or str"):
        eng.clock.mode = mode
    assert eng.clock.mode is pyds.ClockMode.LIVE


def test_clock_set_in_mock_mode():
    """Mock mode lets the harness pin the clock to an absolute value."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.clock.mode = "mock"
    eng.clock.set(123_456)
    assert eng.clock.now_ns == 123_456


def test_clock_advance_in_mock_mode():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.clock.mode = "mock"
    eng.clock.set(1_000)
    eng.clock.advance(500)
    assert eng.clock.now_ns == 1_500


def test_clock_set_in_live_mode_rejected():
    """Setting the clock in live mode is refused with DS_ERR_STATE.

    Live mode reads the OS clock, and pinning it would defeat the point.
    """
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    # The mode is live by default, so setting the clock is refused.
    with pytest.raises(pyds.Error) as caught:
        eng.clock.set(0)
    assert caught.value.status is pyds.Status.STATE


def test_stream_callback_receives_fact_assert():
    """Asserting a fact streams a `fact_assert` with its seq, clock_ns and FactId."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.clock.mode = "mock"
    eng.clock.set(0)

    events = []
    eng.on_event = events.append

    fid = eng.assert_("Trig", v=1)

    asserts = [e for e in events if isinstance(e, pyds.events.FactAssert)]
    assert len(asserts) == 1, events
    assert asserts[0].seq >= 0
    assert asserts[0].clock_ns == 0
    assert asserts[0].fact_id == fid
    assert isinstance(asserts[0].fact_id, pyds.FactId)


def test_on_event_can_be_replaced():
    """Assigning on_event again replaces the callback, and the old one stops receiving."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    a, b = [], []
    eng.on_event = a.append
    eng.assert_("Trig", v=1)
    eng.on_event = b.append
    eng.assert_("Trig", v=2)
    # Each callback saw exactly its own slice.
    assert sum(1 for ev in a if isinstance(ev, pyds.events.FactAssert)) == 1
    assert sum(1 for ev in b if isinstance(ev, pyds.events.FactAssert)) == 1


def test_on_event_can_be_cleared():
    """Assigning None clears the callback, and it reads back as None."""
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    events = []
    eng.on_event = events.append
    assert eng.on_event == events.append
    eng.assert_("Trig", v=1)
    pre = len(events)
    eng.on_event = None
    assert eng.on_event is None
    eng.assert_("Trig", v=2)
    assert len(events) == pre


def test_on_event_refuses_a_non_callable():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(TypeError, match="on_event must be a callable or None, not str"):
        eng.on_event = "not a function"
    assert eng.on_event is None


def test_stream_emits_action_log():
    """A rule firing `log info "..."` streams an action_log with level, category and message."""
    src = (
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig\n"
        "->\n"
        '    log info "hello world"\n'
    )
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    events = []
    eng.on_event = events.append
    eng.assert_("Trig", v=1)
    eng.pump()
    logs = [e for e in events if isinstance(e, pyds.events.ActionLog)]
    assert len(logs) == 1, [e.kind for e in events]
    assert logs[0].level is pyds.LogLevel.INFO
    assert logs[0].category == "r"
    assert logs[0].message == "hello world"


def test_stream_emits_rule_fire_begin_end():
    """A rule firing streams a matching rule_fire_begin and rule_fire_end, with its name."""
    src = 'schema Trig scope logical:\n    v: Int key\n\nrule r:\n    Trig\n->\n    log info "x"\n'
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    events = []
    eng.on_event = events.append
    eng.assert_("Trig", v=1)
    eng.pump()
    begins = [e for e in events if isinstance(e, pyds.events.RuleFireBegin)]
    ends = [e for e in events if isinstance(e, pyds.events.RuleFireEnd)]
    assert begins and begins[0].rule_name == "r"
    assert ends and ends[0].rule_name == "r"


def test_call_callback_receives_request():
    """A `call` action reaches the call callback with its service, correlation and args."""
    src = (
        "service ha.switch.turn_on:\n"
        "    kwarg entity_id: String\n"
        "    no response\n"
        "\n"
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig\n"
        "->\n"
        '    call ha.switch.turn_on entity_id: "switch.fan" '
        'nocooldown as "fan-on"\n'
    )
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    requests = []
    eng.set_call_callback(requests.append)
    eng.assert_("Trig", v=1)
    eng.pump()
    assert len(requests) == 1
    req = requests[0]
    assert req["service"] == "ha.switch.turn_on"
    assert req["correlation"] == "fan-on"
    assert req["args"] == {"entity_id": "switch.fan"}


def test_call_without_callback_surfaces_error():
    """A call with no call callback registered fails the pump (IDSP.6.4).

    `call` is essential, so its policy for a NULL callback is
    DS_ERR_STORAGE_UNAVAILABLE.
    """
    src = (
        "service svc.method:\n"
        '    "stub"\n'
        "    no response\n"
        "\n"
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig\n"
        "->\n"
        "    call svc.method nocooldown\n"
    )
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    eng.assert_("Trig", v=1)
    with pytest.raises(pyds.StorageError) as caught:
        eng.pump()
    assert caught.value.status is pyds.Status.STORAGE_UNAVAILABLE


def test_cache_set_callback_receives_value():
    """A rule's cache write reaches on_cache_set as JSON text, with its TTL in nanoseconds."""
    src = (
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig t\n"
        "->\n"
        '    cache key: "k" value: (t.v * 2) ttl: 1h\n'
    )
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    sets = []
    eng.on_cache_set = lambda key, value_json, ttl_ns: sets.append((key, value_json, ttl_ns))
    eng.assert_("Trig", v=21)
    eng.pump()
    assert len(sets) == 1
    import json as _json

    assert sets[0][0] == "k"
    assert _json.loads(sets[0][1]) == 42
    assert sets[0][2] == 3600000000000


def test_cache_delete_callback():
    src = (
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig\n"
        "->\n"
        '    cache_delete key: "stale"\n'
    )
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    deletes = []
    # delete_cb is (key, reason). The reason is not decoration —
    # NSTG.2.4 says no single response is correct for all the exits, so a
    # callback that cannot see which one fired is wrong whichever way it acts.
    eng.on_cache_delete = lambda k, why: deletes.append((k, why))
    eng.assert_("Trig", v=1)
    eng.pump()
    assert deletes == [("stale", pyds.CacheRemovalReason.DELETE)]
    assert deletes[0][1] is pyds.CacheRemovalReason.DELETE


def test_cache_delete_callback_ttl_reason():
    """The pump-entry TTL sweep reaches on_cache_delete, with reason "ttl" ([NSTG.2.4.2]).

    Nothing reads "k" after it is written: under the lazy-only expiry this
    replaces, the entry never left and this callback never fired at all.
    """
    src = (
        "schema Trig scope logical:\n"
        "    v: Int key\n"
        "\n"
        "rule r:\n"
        "    Trig\n"
        "->\n"
        '    cache key: "k" value: 1 ttl: 5_min\n'
    )
    five_min_ns = 5 * 60 * 1_000_000_000
    eng = pyds.Engine()
    eng.load_dsc(_compile(src))
    removals = []
    eng.on_cache_delete = lambda k, why: removals.append((k, why))
    eng.clock.mode = "mock"
    eng.clock.set(1_000_000)
    eng.assert_("Trig", v=1)
    eng.pump()
    assert removals == []

    # Cross the deadline and pump with nothing asserted — the sweep is the
    # only thing that can remove it.
    eng.clock.set(1_000_000 + five_min_ns)
    eng.pump()
    assert removals == [("k", pyds.CacheRemovalReason.TTL)]


def test_the_two_cache_callbacks_are_set_independently():
    """Setting or clearing one cache callback leaves the other as it was.

    libds registers the two at once, so pyds keeps each one's value.
    """
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    sets, deletes = [], []
    eng.on_cache_set = sets.append
    assert eng.on_cache_delete is None
    eng.on_cache_delete = deletes.append
    assert eng.on_cache_set == sets.append
    eng.on_cache_set = None
    assert eng.on_cache_set is None and eng.on_cache_delete == deletes.append


def test_call_callback_can_be_unset():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    eng.set_call_callback(lambda req: None)
    eng.set_call_callback(None)
    # No assertion beyond "didn't crash"; the unregistration is the
    # observable behaviour (re-firing call after this would surface
    # DS_ERR_STORAGE_UNAVAILABLE — covered by
    # test_call_without_callback_surfaces_error).


def test_call_callback_rejects_non_callable():
    eng = _engine_with("schema Trig scope logical:\n    v: Int key\n")
    with pytest.raises(TypeError, match="callable"):
        eng.set_call_callback("not a function")


def test_ttl_fact_retracts_after_clock_advance():
    """A TTL fact lives until its deadline, and a pump past it retracts the fact.

    This is end to end, through the mock clock, and is the temporal behaviour
    the temporal conformance category leans on.
    """
    eng = _engine_with("schema Pulse scope ttl 100ms:\n    v: Int\n")
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.assert_("Pulse", v=1)
    assert len(eng.facts) == 1

    # Just before deadline: still alive.
    eng.clock.advance(50_000_000)  # 50 ms
    eng.pump()
    assert len(eng.facts) == 1

    # Past deadline: gone after pump.
    eng.clock.advance(100_000_000)  # +100 ms (now at 150 ms)
    eng.pump()
    assert len(eng.facts) == 0
