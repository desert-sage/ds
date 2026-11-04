# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for selecting the most recent fact by `ts` in the LHS.

The selection is a positive pattern plus a `no` pattern over the same schema
with a strictly greater `ts`:

    Reading recent
    no Reading newer where newer.ts > recent.ts

- No matching fact -> the rule does not fire.
- One matching fact -> the rule fires once, bound to it.
- Several -> the rule fires once, for the highest `ts`.
"""

import pyds

_LATEST = """
schema Trig scope logical:
    label: String key

schema Reading scope logical:
    val: Int key
    ts: Time

rule r:
    Trig t
    Reading recent
    no Reading newer where newer.ts > recent.ts
->
    log info "{t.label}={recent.val}"
"""


def test_latest_no_match_rule_does_not_activate():
    """Empty case: no Reading fact, rule does not fire."""
    eng = pyds.from_source(_LATEST)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Trig", label="x")
    eng.pump()

    fires = [r for r in logs if "=" in r.message]
    assert fires == [], f"rule fired without a Reading fact: {fires}"


def test_latest_single_match_fires_once():
    """One Reading fact and one Trig fire the rule once, binding `recent` to the Reading."""
    eng = pyds.from_source(_LATEST)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=42, ts=1)
    eng.assert_("Trig", label="x")
    eng.pump()

    fires = [r.message for r in logs if "=" in r.message]
    assert fires == ["x=42"], fires


def test_latest_with_where_filter_picks_latest_matching():
    """The most recent fact whose predicate holds is the one selected.

    The `no` pattern carries the same predicate, so a later fact that fails it
    does not block the selection.
    """
    src = """
schema Trig scope logical:
    label: String key

schema Reading scope logical:
    val: Int key
    ts: Time
    threshold: Int mutable

rule r:
    Trig t
    Reading recent where recent.threshold > 0
    no Reading newer where newer.threshold > 0 and newer.ts > recent.ts
->
    log info "{t.label}={recent.val}"
"""
    eng = pyds.from_source(src)
    logs = []
    eng.on_log = logs.append

    # val=2 has ts=200 but threshold=0; should be filtered out.
    # val=1 (ts=100) and val=3 (ts=150) pass the filter;
    # latest matching = val=3.
    eng.assert_("Reading", val=1, ts=100, threshold=5)
    eng.assert_("Reading", val=2, ts=200, threshold=0)
    eng.assert_("Reading", val=3, ts=150, threshold=7)
    eng.assert_("Trig", label="x")
    eng.pump()

    fires = [r.message for r in logs if "=" in r.message]
    assert fires == ["x=3"], fires


def test_latest_composes_with_then_chain():
    """The most-recent selection after a `then` chain composes additively.

    The chain's follows-from wiring is undisturbed.
    """
    src = """
schema Tick scope ttl 1_min:
    label: String
    ts: Time

schema Reading scope logical:
    val: Int key
    ts: Time

rule chain:
    Tick a where a.label == "a"
    then Tick b within 5s where b.label == "b"
    Reading recent
    no Reading newer where newer.ts > recent.ts
->
    log info "{a.label}-{b.label}={recent.val}"
"""
    eng = pyds.from_source(src)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=1, ts=100)
    eng.assert_("Reading", val=9, ts=200)
    eng.assert_("Tick", label="a", ts=0)
    eng.clock.set(1_000_000_000)
    eng.assert_("Tick", label="b", ts=1_000_000_000)
    eng.pump()

    fires = [r.message for r in logs if "=" in r.message]
    # then-chain matches a → b, latest picks Reading ts=200 (val=9)
    assert fires == ["a-b=9"], fires


def test_latest_composes_with_negated_pattern():
    """An unrelated `no <Schema>` guard in the rule leaves the most-recent selection alone."""
    src = """
schema Trig scope logical:
    label: String key

schema Block scope logical:
    sentinel: String key

schema Reading scope logical:
    val: Int key
    ts: Time

rule guarded:
    Trig t
    no Block
    Reading recent
    no Reading newer where newer.ts > recent.ts
->
    log info "{t.label}={recent.val}"
"""
    eng = pyds.from_source(src)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=1, ts=100)
    eng.assert_("Reading", val=2, ts=200)
    eng.assert_("Trig", label="x")
    eng.pump()

    fires = [r.message for r in logs if "=" in r.message]
    assert fires == ["x=2"], fires


def test_latest_two_lets_compose():
    """Two most-recent selections on different schemas in one rule combine in one activation."""
    src = """
schema Trig scope logical:
    label: String key

schema Reading scope logical:
    val: Int key
    ts: Time

schema Sample scope logical:
    score: Int key
    ts: Time

rule combine:
    Trig t
    Reading r
    no Reading r2 where r2.ts > r.ts
    Sample s
    no Sample s2 where s2.ts > s.ts
->
    log info "{t.label}:{r.val}/{s.score}"
"""
    eng = pyds.from_source(src)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=1, ts=10)
    eng.assert_("Reading", val=7, ts=20)
    eng.assert_("Sample", score=3, ts=15)
    eng.assert_("Sample", score=99, ts=30)
    eng.assert_("Trig", label="x")
    eng.pump()

    fires = [r.message for r in logs if ":" in r.message]
    assert fires == ["x:7/99"], fires


def test_latest_picks_most_recent_by_ts():
    """Several matching facts fire the rule once, for the highest `ts`.

    Without the `no` pattern it would fire once per fact.
    """
    eng = pyds.from_source(_LATEST)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=1, ts=100)
    eng.assert_("Reading", val=2, ts=200)
    eng.assert_("Reading", val=3, ts=150)
    eng.assert_("Trig", label="x")
    eng.pump()

    fires = [r.message for r in logs if "=" in r.message]
    assert fires == ["x=2"], fires


def test_latest_value_visible_in_rhs_interp():
    """The selected fact's slots resolve in the RHS."""
    eng = pyds.from_source(_LATEST)
    logs = []
    eng.on_log = logs.append

    eng.assert_("Reading", val=7, ts=1)
    eng.assert_("Trig", label="alpha")
    eng.pump()

    msgs = [r.message for r in logs if "=" in r.message]
    assert msgs == ["alpha=7"], msgs
