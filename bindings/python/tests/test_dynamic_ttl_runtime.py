# SPDX-FileCopyrightText: 2026 Dan Finster and the Desert Sage Contributors
# SPDX-License-Identifier: BSD-4-Clause OR AGPL-3.0-or-later
"""Runtime tests for the per-emit `retain:` TTL override.

A rule-RHS `emit <ttl-schema> ... retain: <dur>` overrides the schema's
declared TTL for that specific emission (LDTL.4.1). The fact expires at
`assert_ns + retain_ns`, NOT `assert_ns + schema_ttl_ns` — proven here by
choosing an override (10s) far shorter than the schema TTL (100s) and
observing expiry at the override, while the schema default has not elapsed.
"""

import pyds

# Reading's schema TTL is 100s; the rule overrides it to 10s per emit.
_DYNAMIC_TTL = """
use default:
    dynamic_ttl: true

schema Trig scope logical:
    k: Int key

schema Reading scope ttl 100_s:
    k: Int

rule emit_reading:
    Trig t
->
    emit Reading k: t.k retain: 10_s
"""


def _emit_reading_engine():
    """Fire the rule once at t=0, emitting a Reading with a 10s per-emit TTL."""
    eng = pyds.from_source(_DYNAMIC_TTL)
    eng.clock.mode = "mock"
    eng.clock.set(0)
    eng.assert_("Trig", k=1)
    eng.pump()  # rule fires -> emit Reading retain: 10_s
    return eng


def test_per_emit_retain_alive_before_override_elapses():
    """immature: at 5s (< 10s override) the emitted Reading is still live."""
    eng = _emit_reading_engine()
    assert len(eng.facts) == 2, len(eng.facts)  # Trig + Reading
    eng.clock.set(5_000_000_000)  # 5s
    eng.pump()
    assert len(eng.facts) == 2, f"reading expired before its 10s per-emit TTL: {len(eng.facts)}"


def test_per_emit_retain_expires_at_override_not_schema_ttl():
    """At 15s the Reading has expired by its 10s override, under the schema's 100s TTL.

    The schema TTL has NOT elapsed, which proves the override applied: a
    schema-default expiry would keep it alive until 100s.
    """
    eng = _emit_reading_engine()
    eng.clock.set(15_000_000_000)  # 15s: past the 10s override, well under 100s
    eng.pump()
    assert len(eng.facts) == 1, (
        f"per-emit retain override (10s) not applied — the schema TTL (100s) "
        f"would keep the Reading alive; count={len(eng.facts)}"
    )


def test_per_emit_retain_expiry_emits_fact_retract():
    """The override expiry emits a fact_retract stream event like any other TTL expiry.

    It sweeps through the normal TTL path.
    """
    eng = _emit_reading_engine()
    events = []
    eng.on_event = events.append
    eng.clock.set(15_000_000_000)
    eng.pump()
    retracts = [e for e in events if isinstance(e, pyds.events.FactRetract)]
    assert len(retracts) == 1, (
        f"expected one fact_retract for the override expiry, got {retracts!r}"
    )
