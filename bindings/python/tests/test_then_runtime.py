# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the LGRA `then ... within <dur>` LHS sequence patterns.

The patterns are `then <Schema> b within <dur>` and
`then latest <Schema> b within <dur>`.

The temporal-sequence pattern matches when:
  - the predecessor pattern matches a fact
  - the `then` pattern matches a later fact (b.ts > a.ts)
  - the gap (b.ts - a.ts) is within the declared window
"""

from log_sink import capture_critical

import pyds

_SEQUENCE = """
schema Tick scope ttl 1_min:
    label: String
    ts: Time

rule a_then_b:
    Tick a where a.label == "a"
    then Tick b within 5s where b.label == "b"
->
    log critical "ab"
"""


def test_then_sequence_fires_on_ordered_pair_within_window():
    """Tick 'a' followed by Tick 'b' within the 5-second window fires the rule."""
    eng = pyds.from_source(_SEQUENCE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Tick", label="a", ts=0)
    eng.assert_("Tick", label="b", ts=2_000_000_000)
    eng.pump()
    assert alerts == ["ab"], f"then-sequence didn't fire on within-window pair: {alerts!r}"


def test_then_sequence_silent_when_b_before_a():
    """A b-fact whose ts is BEFORE the a-fact's does not match: the `>` check rejects it."""
    eng = pyds.from_source(_SEQUENCE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Tick", label="a", ts=5_000_000_000)
    eng.assert_("Tick", label="b", ts=0)
    eng.pump()
    assert alerts == [], f"then-sequence fired on out-of-order pair: {alerts!r}"


def test_then_sequence_silent_when_gap_exceeds_window():
    """b.ts - a.ts > 5s should not fire."""
    eng = pyds.from_source(_SEQUENCE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Tick", label="a", ts=0)
    eng.assert_("Tick", label="b", ts=10_000_000_000)
    eng.pump()
    assert alerts == [], f"then-sequence fired on too-wide gap: {alerts!r}"


def test_then_sequence_silent_when_same_ts():
    """LTHE.5.2 — strict ordering: b.ts == a.ts does not match.

    The predicate is `b.ts > a.ts`; simultaneity is rejected.
    """
    eng = pyds.from_source(_SEQUENCE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Tick", label="a", ts=5_000_000_000)
    eng.assert_("Tick", label="b", ts=5_000_000_000)  # identical ts
    eng.pump()
    assert alerts == [], (
        f"then-sequence fired on simultaneous ts (should require strict >): {alerts!r}"
    )


_LATEST_SEQUENCE = """
schema Tick scope ttl 1_min:
    label: String
    n: Int
    ts: Time

rule latest_a_then_b:
    latest Tick a where a.label == "a"
    then Tick b within 10s where b.label == "b"
->
    log critical "ab:{a.n}"
"""


def test_latest_then_pins_to_most_recent_anchor():
    """LTHE.2.5.3 — `latest` pins the anchor to its most recent match before the follower.

    a₂ would itself satisfy the sequence with
    the same b, and is later than a₁, so it excludes a₁.
    """
    eng = pyds.from_source(_LATEST_SEQUENCE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    # `n` names the anchor, so the log says which one fired without
    # depending on how a Time renders.
    eng.assert_("Tick", label="a", n=1, ts=0)  # a₁
    eng.assert_("Tick", label="a", n=2, ts=5_000_000_000)  # a₂
    # b at 8s follows both, within 10s of each: a₂ is the anchor.
    eng.assert_("Tick", label="b", n=0, ts=8_000_000_000)
    eng.pump()
    # Fires exactly once, with anchor a₂.
    assert alerts == ["ab:2"], f"alert didn't reference the most-recent anchor: {alerts!r}"


def test_latest_then_later_anchor_after_b_does_not_exclude():
    """LTHE.2.5.3 — an anchor that arrives after the follower excludes nothing.

    a₂ (10s) follows b (3s), so it cannot satisfy the sequence
    with b, and a₁ then b fires once. Arrival order does not matter:
    a₂ is asserted before b.
    """
    eng = pyds.from_source(_LATEST_SEQUENCE)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    alerts: list[str] = []
    capture_critical(eng, alerts)

    eng.assert_("Tick", label="a", n=1, ts=0)  # a₁
    eng.assert_("Tick", label="a", n=2, ts=10_000_000_000)  # a₂, after b
    eng.assert_("Tick", label="b", n=0, ts=3_000_000_000)  # b, 3s after a₁
    eng.pump()
    assert alerts == ["ab:1"], (
        f"expected one firing on a₁ (a₂ follows b and excludes nothing): {alerts!r}"
    )
