# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for `ttl <dur>` schema lifecycle.

Schemas declared with `scope ttl <dur>` automatically retract
after the duration elapses. The engine sweeps stale facts on
clock advancement.
"""

import pyds

_TTL = """
schema Pulse scope ttl 100ms:
    label: String
"""


def test_ttl_fact_retracts_after_window_elapses():
    """The engine's sweep retracts a ttl fact once the clock passes its TTL."""
    eng = pyds.from_source(_TTL)
    eng.clock.mode = "mock"
    eng.clock.set(0)

    eng.assert_("Pulse", label="ping")
    eng.pump()
    assert len(eng.facts) == 1, len(eng.facts)

    # Advance past the 100ms TTL.
    eng.clock.set(200_000_000)  # 200ms in ns
    eng.pump()
    assert len(eng.facts) == 0, f"ttl didn't retract stale fact: {len(eng.facts)}"


def test_ttl_fact_retract_emits_stream_event():
    """Auto-retraction produces a fact_retract stream event, so subscribers see the lifecycle."""
    eng = pyds.from_source(_TTL)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    events = []
    eng.on_event = events.append

    eng.assert_("Pulse", label="ping")
    eng.clock.set(200_000_000)
    eng.pump()

    retracts = [e for e in events if isinstance(e, pyds.events.FactRetract)]
    assert len(retracts) == 1, f"expected one fact_retract, got {retracts!r}"
